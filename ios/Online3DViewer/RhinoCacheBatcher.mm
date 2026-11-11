#import "RhinoCacheBatcher.h"
#include "NativeMemory.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <sys/statvfs.h>
#include <vector>

namespace {
constexpr size_t MaxInput = 256 * 1024, MaxBatch = 1024 * 1024, MaxParts = 256;
struct Failure { __strong NSString *message; };

NSDictionary *ReadManifest(NSString *directory) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"manifest.json"]];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
void Check(RhinoReadCancellation *cancel, NSString *directory) {
    if (cancel.cancelled) throw Failure{@"读取已取消。"};
    auto memory = o3dv::SampleMemory();
    if (memory.pressure >= 2 || memory.footprint > 448 * o3dv::MemoryMiB ||
        (memory.availableKnown && memory.available < 96 * o3dv::MemoryMiB))
        throw Failure{@"设备内存不足，无法继续整理显示缓存。"};
    struct statvfs storage = {};
    if (statvfs(directory.fileSystemRepresentation, &storage) != 0 ||
        uint64_t(storage.f_bavail) * storage.f_frsize < 512 * o3dv::MemoryMiB)
        throw Failure{@"本地存储空间不足，无法整理显示缓存。"};
}
void CopyFile(NSString *source, NSString *destination) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:destination]) return;
    NSError *error = nil;
    if (![fm linkItemAtPath:source toPath:destination error:&error] &&
        ![fm copyItemAtPath:source toPath:destination error:&error])
        throw Failure{error.localizedDescription ?: @"无法保留原有几何缓存。"};
}
struct Input {
    uint32_t h[8]; const uint8_t *bytes; size_t size;
    explicit Input(NSData *data) : bytes((const uint8_t *)data.bytes), size(data.length) {
        if (size < 32) throw Failure{@"几何缓存头不完整。"};
        std::memcpy(h, bytes, 32);
        if (h[0] != 0x3144334f || h[1] != 1 || h[5] > 1 || h[6] || h[7] || h[3] % 3 || h[4] % 2)
            throw Failure{@"几何缓存格式不支持合并。"};
        uint64_t expected = 32ull + uint64_t(h[2]) * (24 + (h[5] ? 12 : 0)) + uint64_t(h[3]) * 4 + uint64_t(h[4]) * 12;
        if (expected != size) throw Failure{@"几何缓存长度不正确。"};
    }
    float f(size_t offset) const { float v;std::memcpy(&v, bytes + offset, 4);return v; }
    uint32_t u(size_t offset) const { uint32_t v;std::memcpy(&v, bytes + offset, 4);return v; }
};
struct Batch {
    __strong NSDictionary *first = nil;
    __strong NSArray *style = nil;
    __strong NSMutableArray *parts = nil;
    std::vector<float> positions, normals, lines, colors;
    std::vector<uint32_t> indices;
    double origin[3] = {}, bounds[6] = {};
    bool colored = false;

    size_t bytes() const { return 32 + (positions.size()+normals.size()+lines.size()+colors.size()+indices.size())*4; }
    bool empty() const { return first == nil; }
    void clear() { first=nil;style=nil;parts=nil;positions.clear();normals.clear();lines.clear();colors.clear();indices.clear(); }
    void start(NSDictionary *item, NSArray *key, bool color) {
        first=item;style=key;parts=[NSMutableArray array];colored=color;
        for(int i=0;i<3;i++){origin[i]=[item[@"origin"][i] doubleValue];bounds[i]=[item[@"bounds"][i] doubleValue];bounds[i+3]=[item[@"bounds"][i+3] doubleValue];}
    }
    bool fits(const Input &input, NSDictionary *item) const {
        if (parts.count >= MaxParts || bytes()+input.size-32 > MaxBatch) return false;
        for (int kind=0;kind<2;kind++) {
            size_t offset = kind ? 32ull+input.h[2]*24ull+input.h[3]*4ull : 32;
            size_t count = kind ? input.h[4] : input.h[2];
            for(size_t i=0;i<count;i++)for(int axis=0;axis<3;axis++) {
                float value=input.f(offset+i*12+axis*4);
                double delta=[item[@"origin"][axis] doubleValue]-origin[axis], shifted=double(value)+delta;
                if(!std::isfinite(shifted) || std::abs(double(float(shifted))-shifted)>std::max(1e-4,std::abs(double(value))*1e-6))return false;
            }
        }
        return true;
    }
    void append(const Input &input, NSDictionary *item) {
        size_t vertexBase=positions.size()/3, faceStart=indices.size(), lineStart=lines.size()/3;
        for(size_t i=0;i<input.h[2];i++)for(int axis=0;axis<3;axis++) {
            double v=double(input.f(32+i*12+axis*4))+[item[@"origin"][axis] doubleValue]-origin[axis];
            positions.push_back(float(v));
        }
        for(size_t i=0;i<input.h[2]*3ull;i++)normals.push_back(input.f(32ull+input.h[2]*12ull+i*4));
        size_t faces=32ull+input.h[2]*24ull;
        for(size_t i=0;i<input.h[3];i++){auto index=input.u(faces+i*4);if(index>=input.h[2])throw Failure{@"几何缓存顶点索引无效。"};indices.push_back(uint32_t(vertexBase+index));}
        size_t lineOffset=faces+input.h[3]*4ull;
        for(size_t i=0;i<input.h[4];i++)for(int axis=0;axis<3;axis++) {
            double v=double(input.f(lineOffset+i*12+axis*4))+[item[@"origin"][axis] doubleValue]-origin[axis];
            lines.push_back(float(v));
        }
        if(colored)for(size_t i=0;i<input.h[2]*3ull;i++)colors.push_back(input.f(lineOffset+input.h[4]*12ull+i*4));
        [parts addObject:@{@"id":item[@"id"],@"name":item[@"name"]?:@"",@"type":item[@"type"]?:@"",
            @"start":@(faceStart),@"end":@(indices.size()),@"lineStart":@(lineStart),@"lineEnd":@(lines.size()/3)}];
        for(int i=0;i<3;i++){bounds[i]=std::min(bounds[i],[item[@"bounds"][i] doubleValue]);bounds[i+3]=std::max(bounds[i+3],[item[@"bounds"][i+3] doubleValue]);}
    }
    uint64_t write(NSString *path) const {
        FILE *f=fopen(path.fileSystemRepresentation,"wb");if(!f)throw Failure{@"无法写入整理后的几何缓存。"};
        uint32_t header[8]={0x3144334f,1,uint32_t(positions.size()/3),uint32_t(indices.size()),uint32_t(lines.size()/3),uint32_t(colored),0,0};
        bool ok=fwrite(header,1,32,f)==32;
        auto write=[&](const auto &v){size_t n=v.size()*sizeof(v[0]);return !n || fwrite(v.data(),1,n,f)==n;};
        ok=ok&&write(positions)&&write(normals)&&write(indices)&&write(lines)&&write(colors);
        if(fclose(f)!=0)ok=false;if(!ok)throw Failure{@"写入整理后的几何缓存失败。"};return bytes();
    }
};
}

@implementation RhinoCacheBatcher
+ (BOOL)needsBatching:(NSString *)directory {
    @autoreleasepool {
        NSDictionary *m=ReadManifest(directory);
        return [m[@"complete"] boolValue] && [m[@"reader"] isEqual:@"opennurbs-instances-1"] &&
            [m[@"batchingVersion"] integerValue] < 1 && [m[@"objects"] isKindOfClass:NSArray.class] && [m[@"objects"] count] > 1024;
    }
}
+ (BOOL)batchDirectory:(NSString *)source toDirectory:(NSString *)destination progress:(void (^)(NSUInteger, NSUInteger))progress
         cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    NSString *failure=nil;BOOL ok=NO;
    try {
      @try {
        @autoreleasepool {
            NSDictionary *old=ReadManifest(source);
            NSArray *original=old[@"objects"];
            if(![old[@"complete"] boolValue] || ![original isKindOfClass:NSArray.class])throw Failure{@"原始缓存不完整。"};
            NSFileManager *fm=NSFileManager.defaultManager;NSError *e=nil;
            if(![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:&e])throw Failure{e.localizedDescription};
            Check(cancellation,destination);
            NSMutableArray *output=[NSMutableArray array];NSMutableSet *copied=[NSMutableSet set];
            NSString *prefix=[NSString stringWithFormat:@"packed-%@-",NSUUID.UUID.UUIDString];
            Batch batch;uint64_t bytes=0;NSUInteger packed=0;
            auto keep = [&](NSDictionary *item) {
                NSString *name=item[@"url"];
                if(![name isKindOfClass:NSString.class] || ![name isEqual:name.lastPathComponent])throw Failure{@"几何缓存文件名无效。"};
                if(![copied containsObject:name]){CopyFile([source stringByAppendingPathComponent:name],[destination stringByAppendingPathComponent:name]);[copied addObject:name];bytes += [item[@"bytes"] unsignedLongLongValue];}
                NSMutableDictionary *value=[item mutableCopy];value[@"index"]=@(output.count);[output addObject:value];
            };
            auto flush = [&]() {
                if(batch.empty())return;
                if(batch.parts.count==1){keep(batch.first);batch.clear();return;}
                NSString *name=[NSString stringWithFormat:@"%@%06lu.bin",prefix,(unsigned long)packed++];
                uint64_t written=batch.write([destination stringByAppendingPathComponent:name]);bytes+=written;
                NSMutableDictionary *value=[batch.first mutableCopy];
                value[@"id"]=[NSString stringWithFormat:@"o3dv-%@%lu",prefix,(unsigned long)packed];value[@"index"]=@(output.count);
                value[@"name"]=@"";value[@"type"]=@"GeometryBatch";value[@"url"]=name;value[@"bytes"]=@(written);
                value[@"origin"]=@[@(batch.origin[0]),@(batch.origin[1]),@(batch.origin[2])];
                value[@"bounds"]=@[@(batch.bounds[0]),@(batch.bounds[1]),@(batch.bounds[2]),@(batch.bounds[3]),@(batch.bounds[4]),@(batch.bounds[5])];
                value[@"vertices"]=@(batch.positions.size()/3);value[@"triangles"]=@(batch.indices.size()/3);value[@"lineSegments"]=@(batch.lines.size()/6);
                value[@"parts"]=batch.parts;[output addObject:value];batch.clear();
            };
            for(NSUInteger i=0;i<original.count;i++) {
                @autoreleasepool {
                    if(i%128==0){Check(cancellation,destination);progress(i,original.count);}
                    id candidate=original[i];
                    if(![candidate isKindOfClass:NSDictionary.class])throw Failure{@"几何缓存清单无效。"};
                    NSDictionary *item=candidate;
                    id origin=item[@"origin"], bounds=item[@"bounds"];
                    bool eligible=[item[@"available"] boolValue] && ![item[@"definitionMember"] boolValue] && !item[@"transform"] &&
                        !item[@"instanceDefinitionId"] && !item[@"sourceObjectId"] && !item[@"parts"] &&
                        [item[@"opacity"] doubleValue]>=1 && [item[@"bytes"] unsignedLongLongValue]<=MaxInput &&
                        [origin isKindOfClass:NSArray.class] && [origin count]==3 &&
                        [bounds isKindOfClass:NSArray.class] && [bounds count]==6;
                    if(!eligible){flush();keep(item);continue;}
                    NSString *name=item[@"url"];
                    if(![name isKindOfClass:NSString.class] || ![name isEqual:name.lastPathComponent])throw Failure{@"几何缓存文件名无效。"};
                    NSData *data=[NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:name] options:0 error:&e];
                    if(!data || data.length != [item[@"bytes"] unsignedLongLongValue])throw Failure{@"几何缓存文件不完整。"};
                    Input input(data);
                    NSArray *key=@[item[@"layerIndex"]?:@0,item[@"materialIndex"]?:@(-1),item[@"color"]?:@[],item[@"lineColor"]?:@[],
                        item[@"opacity"]?:@1,item[@"visible"]?:@YES,item[@"visibilityLayers"]?:@[],@(input.h[5])];
                    if(!batch.empty() && (![batch.style isEqual:key] || !batch.fits(input,item)))flush();
                    if(batch.empty())batch.start(item,key,input.h[5]);
                    batch.append(input,item);
                }
            }
            flush();Check(cancellation,destination);
            NSMutableDictionary *manifest=[old mutableCopy];manifest[@"objects"]=output;manifest[@"objectCount"]=@(output.count);
            manifest[@"geometryBytes"]=@(bytes);manifest[@"batchingVersion"]=@1;
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&e];
            if(!encoded || ![encoded writeToFile:[destination stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&e])
                throw Failure{e.localizedDescription ?: @"无法保存整理后的模型清单。"};
            progress(original.count,original.count);ok=YES;
        }
      } @catch (NSException *exception) {
          throw Failure{exception.reason ?: @"整理显示缓存失败。"};
      }
    } catch(const Failure &e) { failure=e.message; }
      catch(const std::bad_alloc &) { failure=@"整理显示缓存时内存不足。"; }
      catch(...) { failure=@"整理显示缓存失败。"; }
    if(!ok){[NSFileManager.defaultManager removeItemAtPath:destination error:nil];if(error)*error=[NSError errorWithDomain:@"O3DVRhinoBatch" code:1 userInfo:@{NSLocalizedDescriptionKey:failure?:@"整理显示缓存失败。"}];}
    return ok;
}
@end
