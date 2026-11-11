#import "StlStreamReader.h"
#include "NativeMemory.hpp"
#include "NativeReadLock.hpp"
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <locale.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t BlockTriangles = 16384, InputBytes = 65536;
constexpr uint64_t StorageReserve = 512 * o3dv::MemoryMiB;
struct Failure : std::runtime_error {
    int code;
    Failure(int code, const char *message) : std::runtime_error(message), code(code) {}
};
struct Vec { double v[3] = {}; };
struct Box {
    double lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
    void add(const Vec &p) { for(int k=0;k<3;k++) { lo[k]=std::min(lo[k],p.v[k]);hi[k]=std::max(hi[k],p.v[k]); } }
    NSArray *json() const { return std::isfinite(lo[0]) ? @[@(lo[0]),@(lo[1]),@(lo[2]),@(hi[0]),@(hi[1]),@(hi[2])] : @[@0,@0,@0,@0,@0,@0]; }
};
// Both ASCII tokens and binary records consume the same fixed-size input buffer.
class Input {
    std::array<unsigned char,InputBytes> buffer_;
    size_t at_=0,size_=0;
public:
    std::unique_ptr<FILE,decltype(&fclose)> file;
    uint64_t consumed=0,line=1;
    explicit Input(NSString *path) : file(fopen(path.fileSystemRepresentation,"rb"),&fclose) {
        if(!file) throw Failure(1,"无法打开 STL 文件。");
    }
    int peek() {
        if(at_==size_) {
            size_=fread(buffer_.data(),1,buffer_.size(),file.get());at_=0;
            if(!size_ && ferror(file.get())) throw Failure(1,"STL 文件读取失败。");
        }
        return at_==size_ ? EOF : buffer_[at_];
    }
    int get() { int c=peek();if(c!=EOF) {at_++;consumed++;if(c=='\n')line++;}return c; }
    void read(void *target,size_t count) {
        auto out=static_cast<unsigned char *>(target);
        while(count) {
            if(peek()==EOF) throw Failure(1,"STL 文件不完整，三角形数据已截断。");
            size_t n=std::min(count,size_-at_);memcpy(out,buffer_.data()+at_,n);at_+=n;consumed+=n;out+=n;count-=n;
        }
    }
    void rewind() { clearerr(file.get());if(fseeko(file.get(),0,SEEK_SET)!=0)throw Failure(1,"无法定位 STL 文件。");at_=size_=0;consumed=0;line=1; }
};
struct Context {
    __strong RhinoReadCancellation *cancel;
    __strong void (^progress)(NSDictionary *);
    __strong NSString *directory;
    Input &input;
    uint64_t sourceBytes=0,triangles=0,geometryBytes=0,sourceObjects=0,attributeFacets=0,freeStorage=0;
    size_t peakFootprint=0,peakResident=0;
    Clock::time_point lastCheck={},lastPublish={};
    void checkpoint(bool storage=false,uint64_t required=0) {
        if(cancel.cancelled) throw Failure(3,"读取已取消。");
        auto now=Clock::now();
        if(!storage && now-lastCheck<std::chrono::milliseconds(100) && !o3dv::MemoryPressure().load()) return;
        lastCheck=now;
        auto m=o3dv::SampleMemory();peakFootprint=std::max(peakFootprint,m.footprint);peakResident=std::max(peakResident,m.resident);
        if(m.pressure>=2 || m.footprint>512*o3dv::MemoryMiB || (m.availableKnown && m.available<32*o3dv::MemoryMiB))
            throw Failure(2,"设备当前可用内存不足，已停止 STL 读取，可释放内存后重试。");
        if(storage) {
            struct statvfs fs={};
            if(statvfs(directory.fileSystemRepresentation,&fs)!=0)throw Failure(2,"无法检查模型缓存的可用存储空间。");
            freeStorage=uint64_t(fs.f_bavail)*fs.f_frsize;
            if(freeStorage<StorageReserve || required>freeStorage-StorageReserve)
                throw Failure(2,"设备存储空间不足以保存完整模型缓存，请清理缓存或存储后重试。");
        }
    }
};
// Normalize in double precision, including zero/very large finite source normals.
Vec Unit(Vec n) {
    double scale=std::max({std::abs(n.v[0]),std::abs(n.v[1]),std::abs(n.v[2])});
    if(!scale)return {};
    for(double &x:n.v)x/=scale;
    double length=std::hypot(n.v[0],n.v[1],n.v[2]);for(double &x:n.v)x/=length;return n;
}
struct Chunk {
    std::vector<float> positions,normals;
    std::vector<uint32_t> indices;
    Vec origin;
    Box bounds;
    Chunk() { positions.reserve(BlockTriangles*9);normals.reserve(BlockTriangles*9);indices.reserve(BlockTriangles*3); }
    void clear() {positions.clear();normals.clear();indices.clear();bounds=Box();}
    void add(const Vec (&points)[3],Vec normal) {
        if(indices.empty())origin=points[0];
        for(const auto &p:points)for(double x:p.v)if(!std::isfinite(x))throw Failure(1,"STL 包含非有限坐标。");
        for(double x:normal.v)if(!std::isfinite(x))throw Failure(1,"STL 包含非有限法线。");
        normal=Unit(normal);
        if(normal.v[0]==0 && normal.v[1]==0 && normal.v[2]==0) {
            Vec u,v;
            for(int k=0;k<3;k++) {u.v[k]=points[1].v[k]-points[0].v[k];v.v[k]=points[2].v[k]-points[0].v[k];}
            u=Unit(u);v=Unit(v);
            normal=Unit({{u.v[1]*v.v[2]-u.v[2]*v.v[1],u.v[2]*v.v[0]-u.v[0]*v.v[2],u.v[0]*v.v[1]-u.v[1]*v.v[0]}});
        }
        for(const auto &p:points) {
            indices.push_back(uint32_t(positions.size()/3));bounds.add(p);
            for(int k=0;k<3;k++) {
                double local=p.v[k]-origin.v[k];
                if(!std::isfinite(local) || std::abs(local)>std::numeric_limits<float>::max())
                    throw Failure(1,"STL 坐标范围超过显示数据可表示的范围。");
                positions.push_back(float(local));normals.push_back(float(normal.v[k]));
            }
        }
    }
    uint64_t bytes() const {return 32+positions.size()*4+normals.size()*4+indices.size()*4;}
    void write(NSString *path) {
        std::unique_ptr<FILE,decltype(&fclose)> out(fopen(path.fileSystemRepresentation,"wb"),&fclose);
        if(!out)throw Failure(2,"无法创建 STL 几何缓存。");
        uint32_t header[8]={0x3144334f,2,uint32_t(positions.size()/3),uint32_t(indices.size()),0,0,0,0};
        auto append=[&](const void *p,size_t n) {if(fwrite(p,1,n,out.get())!=n)throw Failure(2,"STL 缓存写入失败，请检查剩余存储空间。");};
        append(header,sizeof(header));append(positions.data(),positions.size()*4);append(normals.data(),normals.size()*4);append(indices.data(),indices.size()*4);
        if(fflush(out.get())!=0)throw Failure(2,"STL 缓存写入失败，请检查剩余存储空间。");
    }
};
uint32_t U32(const unsigned char *p) {return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;}
float F32(const unsigned char *p) {uint32_t bits=U32(p);float f;memcpy(&f,&bits,4);return f;}
// STL solid names/comments may be long; discard the tail without accumulating it.
class Tokens {
    Input &in_;Context &context_;
    locale_t locale_=newlocale(LC_NUMERIC_MASK,"C",nullptr);
    size_t sinceCheck_=0;
    int get() {if(++sinceCheck_>=4096){context_.checkpoint();sinceCheck_=0;}return in_.get();}
public:
    Tokens(Input &input,Context &context) : in_(input),context_(context) {if(!locale_)throw Failure(2,"无法初始化 STL 数值读取器。");}
    ~Tokens() {freelocale(locale_);}
    std::string restOfLine() {
        std::string result;bool comment=false;
        while(in_.peek()!=EOF && in_.peek()!='\n' && in_.peek()!='\r') {
            int c=get();if(c=='#')comment=true;if(!comment && result.size()<1024)result+=char(c);
        }
        while(!result.empty() && (result.back()==' ' || result.back()=='\t'))result.pop_back();
        size_t start=result.find_first_not_of(" \t");return start==std::string::npos?std::string():result.substr(start);
    }
    bool next(std::string &token) {
        token.clear();
        while(true) {
            int c=in_.peek();if(c==EOF)return false;
            if(c=='#') {restOfLine();continue;}
            if(c==' ' || c=='\t' || c=='\n' || c=='\r' || c=='\f' || c=='\v') {get();continue;}
            break;
        }
        while(in_.peek()!=EOF) {
            int c=in_.peek();if(c=='#' || c==' ' || c=='\t' || c=='\n' || c=='\r' || c=='\f' || c=='\v')break;
            if(c==0 || c>127 || token.size()>=1024)throw Failure(1,"STL 文本包含无效或过长的数据项。");
            token+=char(get());
        }
        return true;
    }
    std::string word() {std::string token;if(!next(token))throw Failure(1,"STL 文本未完成，文件已结束。");return token;}
    void expect(const char *expected) {if(word()!=expected)throw Failure(1,"STL 文本结构无效，三角面未完整定义。");}
    Vec vector() {
        Vec result;
        for(double &x:result.v) {auto token=word();char *end=nullptr;x=strtod_l(token.c_str(),&end,locale_);
            if(end!=token.c_str()+token.size() || !std::isfinite(x))throw Failure(1,"STL 包含无效数值或非有限坐标。");}
        return result;
    }
};
}

@implementation StlStreamReader
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory progress:(void (^)(NSDictionary<NSString *,id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    // Retain NSError outside inner autorelease pools, including malformed/low-resource failures.
    __strong NSError *operationError=nil;
    std::unique_lock<std::mutex> lock(o3dv::NativeReadMutex());
    @autoreleasepool {
        try {
            Input input(source);
            struct stat st={};if(fstat(fileno(input.file.get()),&st)!=0 || st.st_size<1)throw Failure(1,"STL 文件为空或无法读取。");
            if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&operationError]) {
                if(error)*error=operationError;return NO;
            }
            Context c{cancellation,progress,directory,input};c.sourceBytes=uint64_t(st.st_size);c.checkpoint(true);
            unsigned char header[84]={};
            size_t prefix=size_t(std::min<uint64_t>(84,c.sourceBytes));input.read(header,prefix);input.rewind();
            uint32_t binaryCount=prefix==84?U32(header+80):0;
            bool binary=prefix==84 && 84+uint64_t(binaryCount)*50==c.sourceBytes;
            if(!binary) {
                size_t start=(prefix>=3 && header[0]==0xef && header[1]==0xbb && header[2]==0xbf)?3:0;
                for(size_t i=start;i<prefix;i++)if(header[i]==0 || (header[i]<32 && header[i]!='\t' && header[i]!='\r' && header[i]!='\n' && header[i]!='\f'))
                    throw Failure(1,"STL 二进制长度与声明的三角形数量不匹配，文件可能已损坏或截断。");
                if(start) {unsigned char bom[3];input.read(bom,3);}
            }
            if(binary) {
                if(!binaryCount)throw Failure(1,"STL 文件没有可显示的三角面。");
                // Exact geometry size plus a conservative allowance for atomic manifests.
                c.checkpoint(true,uint64_t(binaryCount)*84+((uint64_t(binaryCount)+BlockTriangles-1)/BlockTriangles)*4096);
                input.read(header,84);
            }
            NSMutableArray *objects=[NSMutableArray array];
            NSMutableDictionary *manifest=[@{@"format":@"o3dv-stream-1",@"reader":@"stl-stream-1",@"name":source.lastPathComponent,
                @"sourceBytes":@(c.sourceBytes),@"encoding":binary?@"binary":@"ascii",@"maxBlockTriangles":@(BlockTriangles),
                @"layers":@[@{@"id":@"model",@"index":@0,@"name":@"模型",@"visible":@YES}],
                @"materials":@[],@"objects":objects,@"unsupported":@[],@"missingFiles":@[],@"complete":@NO} mutableCopy];
            Chunk chunk;Box bounds;bool published=false;
            __strong NSString *solidID=@"stl-solid-0",*solidName=source.lastPathComponent.stringByDeletingPathExtension;
            auto publish=[&](NSString *phase) {
                @autoreleasepool {
                    c.checkpoint(true,objects.count*4096+16384);
                    [manifest addEntriesFromDictionary:@{@"objectCount":@(objects.count),@"sourceObjectCount":@(c.sourceObjects),
                        @"geometryBytes":@(c.geometryBytes),@"vertices":@(c.triangles*3),@"triangles":@(c.triangles),@"sourceTriangles":@(c.triangles),
                        @"lineSegments":@0,@"bounds":bounds.json(),@"nonzeroAttributeFacets":@(c.attributeFacets),
                        @"nativePeakFootprintBytes":@(c.peakFootprint),@"nativePeakMemoryBytes":@(c.peakResident),
                        @"geometryBufferCapacityBytes":@(BlockTriangles*84),@"inputBufferBytes":@(InputBytes)}];
                    NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&operationError];
                    if(!data || ![data writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&operationError])
                        throw Failure(2,"无法写入 STL 模型清单，请检查剩余存储空间。");
                    progress(@{@"phase":phase,@"objects":@(c.sourceObjects),@"bytesRead":@(input.consumed),@"sourceBytes":@(c.sourceBytes),@"triangles":@(c.triangles)});
                    published=true;c.lastPublish=Clock::now();
                }
            };
            auto flush=[&]() {
                if(chunk.indices.empty())return;
                @autoreleasepool {
                    c.checkpoint(true,chunk.bytes()+objects.count*4096+16384);
                    NSString *name=[NSString stringWithFormat:@"object-%06lu.bin",(unsigned long)objects.count];
                    chunk.write([directory stringByAppendingPathComponent:name]);
                    [objects addObject:@{@"id":[NSString stringWithFormat:@"chunk-%lu",(unsigned long)objects.count],@"index":@(objects.count),
                        @"name":solidName,@"type":@"Mesh",@"layerIndex":@0,@"materialIndex":@(-1),@"color":@[@0.7,@0.72,@0.75],@"opacity":@1,
                        @"lineColor":@[@0.25,@0.25,@0.25],@"visible":@YES,@"definitionMember":@NO,@"available":@YES,
                        @"origin":@[@(chunk.origin.v[0]),@(chunk.origin.v[1]),@(chunk.origin.v[2])],@"bounds":chunk.bounds.json(),@"url":name,
                        @"bytes":@(chunk.bytes()),@"vertices":@(chunk.positions.size()/3),@"triangles":@(chunk.indices.size()/3),@"lineSegments":@0,
                        @"parts":@[@{@"id":solidID,@"name":solidName,@"type":@"Mesh",@"start":@0,@"end":@(chunk.indices.size()),@"lineStart":@0,@"lineEnd":@0,
                                     @"sourceTriangleStart":@(c.triangles-chunk.indices.size()/3)}]}];
                    c.geometryBytes+=chunk.bytes();chunk.clear();
                    if(!published || Clock::now()-c.lastPublish>std::chrono::milliseconds(200))publish(published?@"parsing":@"ready");
                }
                c.checkpoint();
            };
            auto add=[&](const Vec (&points)[3],Vec normal) {
                chunk.add(points,normal);for(const auto &p:points)bounds.add(p);c.triangles++;
                if(chunk.indices.size()/3==BlockTriangles)flush();
                if((c.triangles&1023)==0)c.checkpoint();
            };
            if(binary) {
                c.sourceObjects=1;unsigned char record[50];
                for(uint64_t i=0;i<binaryCount;i++) {
                    input.read(record,sizeof(record));Vec normal,points[3];
                    for(int k=0;k<3;k++)normal.v[k]=F32(record+k*4);
                    for(int j=0;j<3;j++)for(int k=0;k<3;k++)points[j].v[k]=F32(record+12+j*12+k*4);
                    if(record[48] || record[49])c.attributeFacets++;
                    add(points,normal);
                }
            } else {
                Tokens tokens(input,c);std::string token;bool inSolid=false,solidHasFaces=false;uint64_t solids=0;
                while(tokens.next(token)) {
                    if(token=="solid" && !inSolid) {
                        inSolid=true;solidHasFaces=false;
                        solidID=[NSString stringWithFormat:@"stl-solid-%llu",(unsigned long long)solids++];
                        auto name=tokens.restOfLine();solidName=[[NSString alloc] initWithBytes:name.data() length:name.size() encoding:NSUTF8StringEncoding];
                        if(!solidName.length)solidName=source.lastPathComponent.stringByDeletingPathExtension;
                    } else if(token=="facet" && inSolid) {
                        auto word=tokens.word();Vec normal,points[3];
                        if(word=="normal") {normal=tokens.vector();tokens.expect("outer");}
                        else if(word!="outer")throw Failure(1,"STL 三角面缺少 outer loop。");
                        tokens.expect("loop");
                        for(auto &p:points) {tokens.expect("vertex");p=tokens.vector();}
                        tokens.expect("endloop");tokens.expect("endfacet");
                        if(!solidHasFaces) {solidHasFaces=true;c.sourceObjects++;}
                        add(points,normal);
                    } else if(token=="endsolid" && inSolid) {
                        flush();tokens.restOfLine();inSolid=false;
                    } else throw Failure(1,"STL 文本结构无效，应包含完整的 solid 和三角面。");
                }
                if(inSolid)throw Failure(1,"STL 文本缺少 endsolid，文件可能已截断。");
            }
            if(!c.triangles)throw Failure(1,"STL 文件没有可显示的三角面。");
            flush();c.checkpoint();manifest[@"complete"]=@YES;publish(@"complete");return YES;
        } catch(const Failure &failure) {
            operationError=[NSError errorWithDomain:@"O3DVSTL" code:failure.code userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:failure.what()]}];
        } catch(const std::bad_alloc &) {
            operationError=[NSError errorWithDomain:@"O3DVSTL" code:2 userInfo:@{NSLocalizedDescriptionKey:@"设备当前可用内存不足，已停止 STL 读取。"}];
        } catch(const std::exception &failure) {
            operationError=[NSError errorWithDomain:@"O3DVSTL" code:1 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithUTF8String:failure.what()]}];
        }
    }
    if(error)*error=operationError;return NO;
}
@end
