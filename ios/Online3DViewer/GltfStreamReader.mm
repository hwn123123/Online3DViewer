#import "GltfStreamReader.h"
#include "NativeMemory.hpp"
#include "NativeReadLock.hpp"
#include "DracoMemory.hpp"
#include "draco/compression/decode.h"
#include "draco/mesh/mesh_stripifier.h"
#define CGLTF_IMPLEMENTATION
#include "ThirdParty/cgltf/cgltf.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

namespace {
using Clock=std::chrono::steady_clock;
constexpr size_t MiB=1024*1024,BlockCorners=24576,MetadataLimit=64*MiB;
struct Failure:std::runtime_error {int code;Failure(int c,const std::string &s):std::runtime_error(s),code(c){}};
NSString *Text(const char *s) {return s?[NSString stringWithUTF8String:s]?:@"":@"";}
struct Mapping {
    int fd=-1;size_t size=0;void *data=MAP_FAILED;
    explicit Mapping(NSString *path) {
        fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC);struct stat st={};
        if(fd<0 || fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size<=0) {if(fd>=0)close(fd);fd=-1;throw Failure(1,"无法读取本地文件："+std::string(path.lastPathComponent.UTF8String));}
        size=size_t(st.st_size);data=mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);
        if(data==MAP_FAILED){close(fd);fd=-1;throw Failure(2,"无法映射本地模型文件，设备地址空间不足。");}
        madvise(data,size,MADV_RANDOM);
    }
    ~Mapping(){if(data!=MAP_FAILED)munmap(data,size);if(fd>=0)close(fd);}
};
struct alignas(std::max_align_t) Allocation {size_t bytes;};
struct MetadataMemory {
    size_t bytes=0,peak=0;bool limited=false;
    static void *allocate(void *user,size_t n) {
        auto &m=*static_cast<MetadataMemory *>(user);
        if(n>MetadataLimit-m.bytes || n>SIZE_MAX-sizeof(Allocation)){m.limited=true;return nullptr;}
        auto p=static_cast<Allocation *>(malloc(sizeof(Allocation)+n));if(!p){m.limited=true;return nullptr;}
        p->bytes=n;m.bytes+=n;m.peak=std::max(m.peak,m.bytes);return p+1;
    }
    static void release(void *user,void *p) {if(!p)return;auto &m=*static_cast<MetadataMemory *>(user);auto a=static_cast<Allocation *>(p)-1;m.bytes-=a->bytes;free(a);}
};
using V=std::array<double,3>;
using M=std::array<double,16>;
M Identity(){return {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};}
M Multiply(const M &a,const M &b){M out={};for(int col=0;col<4;col++)for(int row=0;row<4;row++)for(int k=0;k<4;k++)out[col*4+row]+=a[k*4+row]*b[col*4+k];return out;}
V Position(const M &m,V p){V out={};for(int r=0;r<3;r++)out[r]=m[r]*p[0]+m[4+r]*p[1]+m[8+r]*p[2]+m[12+r];return out;}
V Unit(V n){double d=std::max({std::abs(n[0]),std::abs(n[1]),std::abs(n[2])});if(!d)return {};for(auto &v:n)v/=d;d=std::hypot(n[0],n[1],n[2]);for(auto &v:n)v/=d;return n;}
V Cross(V a,V b){return {a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]};}
M Inverse(const M &m) {
    double a[4][8]={};for(int r=0;r<4;r++){for(int c=0;c<4;c++)a[r][c]=m[c*4+r];a[r][r+4]=1;}
    for(int c=0;c<4;c++) {
        int p=c;for(int r=c+1;r<4;r++)if(std::abs(a[r][c])>std::abs(a[p][c]))p=r;
        if(std::abs(a[p][c])<1e-30)throw Failure(1,"模型包含不可逆的骨骼变换。");
        if(p!=c)for(int k=0;k<8;k++)std::swap(a[p][k],a[c][k]);
        double d=a[c][c];for(auto &v:a[c])v/=d;
        for(int r=0;r<4;r++)if(r!=c){d=a[r][c];for(int k=0;k<8;k++)a[r][k]-=d*a[c][k];}
    }
    M out;for(int r=0;r<4;r++)for(int c=0;c<4;c++)out[c*4+r]=a[r][c+4];return out;
}
V Normal(const M &m,V p){auto inverse=Inverse(m);return Unit({inverse[0]*p[0]+inverse[1]*p[1]+inverse[2]*p[2],inverse[4]*p[0]+inverse[5]*p[1]+inverse[6]*p[2],inverse[8]*p[0]+inverse[9]*p[1]+inverse[10]*p[2]});}
NSArray *JSON(const M &m){NSMutableArray *out=[NSMutableArray array];for(double v:m){if(!std::isfinite(v))throw Failure(1,"模型包含无效变换。");[out addObject:@(v)];}return out;}
struct Box {
    V lo={INFINITY,INFINITY,INFINITY},hi={-INFINITY,-INFINITY,-INFINITY};
    void add(V p){for(int k=0;k<3;k++){if(!std::isfinite(p[k]))throw Failure(1,"模型包含非有限坐标。");lo[k]=std::min(lo[k],p[k]);hi[k]=std::max(hi[k],p[k]);}}
    void add(const Box &b){if(std::isfinite(b.lo[0])){add(b.lo);add(b.hi);}}
    Box placed(const M &m)const{Box b;for(int i=0;i<8;i++)b.add(Position(m,{(i&1)?hi[0]:lo[0],(i&2)?hi[1]:lo[1],(i&4)?hi[2]:lo[2]}));return b;}
    NSArray *json()const{return std::isfinite(lo[0])?@[@(lo[0]),@(lo[1]),@(lo[2]),@(hi[0]),@(hi[1]),@(hi[2])]:@[@0,@0,@0,@0,@0,@0];}
};
struct Context {
    __strong RhinoReadCancellation *cancel;
    __strong void (^progress)(NSDictionary *);
    __strong NSString *directory,*root;
    __strong NSMutableArray *missing=[NSMutableArray array];
    std::vector<std::unique_ptr<Mapping>> maps;
    __strong NSMutableArray *temporaries=[NSMutableArray array];
    uint64_t sourceBytes=0,work=0,totalWork=1,geometryBytes=0,triangles=0,lines=0,points=0,sourceObjects=0;
    size_t peakFootprint=0,peakResident=0,dracoPeakBytes=0,dracoMeshCount=0,dracoBudgetBytes=1024*MiB,dracoWorkspaceBytes=0;
    Clock::time_point lastCheck={},lastPublish={};
    Context(RhinoReadCancellation *cancel,void (^progress)(NSDictionary *),NSString *directory,NSString *root)
        :cancel(cancel),progress(progress),directory(directory),root(root){}
    ~Context(){for(NSString *file in temporaries)[NSFileManager.defaultManager removeItemAtPath:file error:nil];}
    void checkpoint(bool disk=false,uint64_t needed=0) {
        if(cancel.cancelled)throw Failure(3,"读取已取消。");
        auto now=Clock::now();if(!disk && now-lastCheck<std::chrono::milliseconds(100) && !o3dv::MemoryPressure().load())return;lastCheck=now;
        auto m=o3dv::SampleMemory();peakFootprint=std::max(peakFootprint,m.footprint);peakResident=std::max(peakResident,m.resident);
        if(m.pressure>=2 || m.footprint>512*MiB || (m.availableKnown && m.available<32*MiB))throw Failure(2,"设备当前可用内存不足，已停止 GLB / glTF 读取。");
        if(disk){struct statvfs fs={};if(statvfs(directory.fileSystemRepresentation,&fs))throw Failure(2,"无法检查缓存存储空间。");uint64_t free=uint64_t(fs.f_bavail)*fs.f_frsize;
            if(free<512*MiB || needed>free-512*MiB)throw Failure(2,"设备存储空间不足，无法保存完整 GLB / glTF 缓存。");}
    }
    Mapping &map(NSString *path){maps.push_back(std::make_unique<Mapping>(path));return *maps.back();}
    NSString *local(const char *uri,bool optional=false) {
        NSString *name=[Text(uri) stringByRemovingPercentEncoding];
        if(!name || [name containsString:@":"] || [name hasPrefix:@"/"] || [name containsString:@"\\"])
            throw Failure(1,"模型引用了非本地或无效的配套文件路径。");
        NSString *path=[[root stringByAppendingPathComponent:name] stringByResolvingSymlinksInPath];
        if(![path hasPrefix:[root stringByAppendingString:@"/"]])throw Failure(1,"模型配套文件路径超出已导入的目录。");
        if(![NSFileManager.defaultManager fileExistsAtPath:path]) {
            // The system multi-file picker copies selected companions into one import directory.
            NSString *flat=[[root stringByAppendingPathComponent:name.lastPathComponent] stringByResolvingSymlinksInPath];
            if([flat hasPrefix:[root stringByAppendingString:@"/"]] && [NSFileManager.defaultManager fileExistsAtPath:flat])return flat;
            if(optional){if(![missing containsObject:name])[missing addObject:name];return nil;}
            throw Failure(1,"缺少模型必需的本地配套文件："+std::string(name.UTF8String));
        }
        return path;
    }
    void write(const void *bytes,size_t count,NSString *path) {
        checkpoint(true,count);std::unique_ptr<FILE,decltype(&fclose)> out(fopen(path.fileSystemRepresentation,"wb"),&fclose);
        if(!out)throw Failure(2,"无法创建模型缓存文件。");
        for(size_t offset=0;offset<count;offset+=65536){checkpoint();size_t n=std::min(size_t(65536),count-offset);if(fwrite(static_cast<const char *>(bytes)+offset,1,n,out.get())!=n)throw Failure(2,"模型缓存写入失败。");}
        if(fflush(out.get()))throw Failure(2,"模型缓存写入失败。");
    }
    void dataURI(const char *uri,NSString *path) {
        const char *comma=strchr(uri,',');if(!comma || std::string(uri,size_t(comma-uri)).find(";base64")==std::string::npos)throw Failure(1,"暂不支持此 data URI 编码，需使用 base64。");
        checkpoint(true,strlen(comma+1)/4*3+3);std::unique_ptr<FILE,decltype(&fclose)> out(fopen(path.fileSystemRepresentation,"wb"),&fclose);
        if(!out)throw Failure(2,"无法创建内嵌数据缓存。");
        std::array<unsigned char,65536> buffer;size_t used=0;uint32_t bits=0;int count=0,padding=0;bool ended=false;
        for(const unsigned char *p=reinterpret_cast<const unsigned char *>(comma+1);*p;p++) {
            int ch=*p;if(ch==' '||ch=='\n'||ch=='\r'||ch=='\t')continue;
            if(ch=='='){ended=true;padding++;if(padding>2)throw Failure(1,"base64 填充无效。");continue;}
            int v=ch>='A'&&ch<='Z'?ch-'A':ch>='a'&&ch<='z'?ch-'a'+26:ch>='0'&&ch<='9'?ch-'0'+52:ch=='+'?62:ch=='/'?63:-1;
            if(v<0||ended)throw Failure(1,"模型包含无效 base64 数据。");bits=(bits<<6)|uint32_t(v);count+=6;
            if(count>=8){count-=8;buffer[used++]=unsigned((bits>>count)&255);}
            if(used==buffer.size()){checkpoint();if(fwrite(buffer.data(),1,used,out.get())!=used)throw Failure(2,"内嵌数据写入失败。");used=0;}
        }
        if(count==6 || (padding && count!=padding*2) || (count && (bits&((1u<<count)-1))))throw Failure(1,"base64 数据长度无效。");
        if((used&&fwrite(buffer.data(),1,used,out.get())!=used)||fflush(out.get()))throw Failure(2,"内嵌数据写入失败。");
    }
};
bool Span(size_t offset,size_t stride,size_t count,size_t element,size_t length){return count && stride>=element && offset<=length && element<=length-offset && count-1<=(length-offset-element)/stride;}
void Validate(cgltf_data *d,Context &c) {
    // Validate every byte range with overflow-safe arithmetic before cgltf dereferences buffers.
    for(size_t i=0;i<d->buffer_views_count;i++) {
        auto &v=d->buffer_views[i];if(v.has_meshopt_compression)throw Failure(4,"当前原生读取路径尚未接入 Meshopt 压缩扩展。");
        if(!v.buffer || v.offset>v.buffer->size || v.size>v.buffer->size-v.offset)throw Failure(1,"bufferView 超出本地数据范围。");
    }
    for(size_t i=0;i<d->accessors_count;i++) {
        c.checkpoint();auto &a=d->accessors[i];size_t element=cgltf_calc_size(a.type,a.component_type),component=cgltf_component_size(a.component_type);
        if(!element || !component || !a.count || (a.buffer_view && !Span(a.offset,a.stride,a.count,element,a.buffer_view->size)))throw Failure(1,"accessor 的范围或类型无效。");
        if(a.buffer_view && ((a.buffer_view->offset+a.offset)%component || a.stride%component))throw Failure(1,"accessor 数据未正确对齐。");
        if(a.is_sparse){auto &s=a.sparse;size_t size=cgltf_component_size(s.indices_component_type);
            if(!s.indices_buffer_view||!s.values_buffer_view||s.count>a.count||!size ||
                !(s.indices_component_type==cgltf_component_type_r_8u||s.indices_component_type==cgltf_component_type_r_16u||s.indices_component_type==cgltf_component_type_r_32u)||
                !Span(s.indices_byte_offset,size,s.count,size,s.indices_buffer_view->size)||!Span(s.values_byte_offset,element,s.count,element,s.values_buffer_view->size))throw Failure(1,"稀疏 accessor 的数据范围无效。");
            if((s.indices_buffer_view->offset+s.indices_byte_offset)%size || (s.values_buffer_view->offset+s.values_byte_offset)%component)
                throw Failure(1,"稀疏 accessor 数据未正确对齐。");
            // cgltf sparse lookup uses accessor stride; sparse values are tightly packed by the specification.
            size_t previous=0;const auto *p=cgltf_buffer_view_data(s.indices_buffer_view)+s.indices_byte_offset;
            for(size_t j=0;j<s.count;j++){if((j&4095)==0)c.checkpoint();auto index=cgltf_component_read_index(p+j*size,s.indices_component_type);if(index>=a.count||(j&&index<=previous))throw Failure(1,"稀疏 accessor 的索引无效或未递增。");previous=index;}
        }
    }
    for(size_t i=0;i<d->nodes_count;i++) {auto &n=d->nodes[i];for(size_t j=0;j<n.children_count;j++)if(n.children[j]->parent!=&n)throw Failure(1,"模型节点存在重复父节点。");}
}
size_t ReadIndex(const cgltf_accessor *a,size_t index) {
    if(index>=a->count)throw Failure(1,"索引 accessor 越界。");
    if(a->is_sparse){const auto &s=a->sparse;size_t size=cgltf_component_size(s.indices_component_type),lo=0,hi=s.count;
        const auto *p=cgltf_buffer_view_data(s.indices_buffer_view)+s.indices_byte_offset;
        while(lo<hi){size_t mid=lo+(hi-lo)/2;if(cgltf_component_read_index(p+mid*size,s.indices_component_type)<index)lo=mid+1;else hi=mid;}
        if(lo<s.count&&cgltf_component_read_index(p+lo*size,s.indices_component_type)==index)
            return cgltf_component_read_index(cgltf_buffer_view_data(s.values_buffer_view)+s.values_byte_offset+lo*cgltf_component_size(a->component_type),a->component_type);
    }
    cgltf_accessor base=*a;base.is_sparse=0;return cgltf_accessor_read_index(&base,index);
}
void Read(const cgltf_accessor *a,size_t index,float *out,size_t components) {
    if(!a || index>=a->count)throw Failure(1,"几何顶点索引超出 accessor 范围。");
    // cgltf's sparse helper assumes the base stride also applies to sparse values. Handle packed overrides explicitly.
    cgltf_accessor base=*a;base.is_sparse=0;
    if(a->is_sparse){const auto &s=a->sparse;size_t size=cgltf_component_size(s.indices_component_type),lo=0,hi=s.count;
        const auto *p=cgltf_buffer_view_data(s.indices_buffer_view)+s.indices_byte_offset;
        while(lo<hi){size_t mid=lo+(hi-lo)/2;if(cgltf_component_read_index(p+mid*size,s.indices_component_type)<index)lo=mid+1;else hi=mid;}
        if(lo<s.count && cgltf_component_read_index(p+lo*size,s.indices_component_type)==index){
            const auto *v=cgltf_buffer_view_data(s.values_buffer_view)+s.values_byte_offset+lo*cgltf_calc_size(a->type,a->component_type);
            if(!cgltf_element_read_float(v,a->type,a->component_type,a->normalized,out,components))throw Failure(1,"无法读取稀疏顶点属性。");
            for(size_t k=0;k<components;k++)if(!std::isfinite(out[k]))throw Failure(1,"模型属性包含非有限数值。");return;
        }
    }
    if(!cgltf_accessor_read_float(&base,index,out,components))throw Failure(1,"无法读取顶点属性。");
    for(size_t k=0;k<components;k++)if(!std::isfinite(out[k]))throw Failure(1,"模型属性包含非有限数值。");
}
const cgltf_accessor *Attribute(const cgltf_primitive &p,cgltf_attribute_type type,int index=0){for(size_t i=0;i<p.attributes_count;i++)if(p.attributes[i].type==type&&p.attributes[i].index==index)return p.attributes[i].data;return nullptr;}
struct Vertex {V p={},n={};std::array<float,4> color={1,1,1,1},tangent={0,0,0,1};std::array<float,2> uv={},uv1={};};
struct Chunk {
    std::vector<float> positions,normals,colors,uv,uv1,tangents;
    std::vector<uint32_t> indices;V origin={};Box bounds;bool hasColors=false,hasUV=false,hasUV1=false,hasTangents=false;
    void add(const Vertex &v){if(indices.empty())origin=v.p;indices.push_back(uint32_t(indices.size()));bounds.add(v.p);
        for(int k=0;k<3;k++){double local=v.p[k]-origin[k];if(!std::isfinite(local)||std::abs(local)>std::numeric_limits<float>::max())throw Failure(1,"模型坐标范围超过显示能力。");positions.push_back(float(local));normals.push_back(float(v.n[k]));}
        if(hasColors)colors.insert(colors.end(),v.color.begin(),v.color.end());if(hasUV)uv.insert(uv.end(),v.uv.begin(),v.uv.end());if(hasUV1)uv1.insert(uv1.end(),v.uv1.begin(),v.uv1.end());if(hasTangents)tangents.insert(tangents.end(),v.tangent.begin(),v.tangent.end());}
    size_t bytes()const{return 32+(positions.size()+normals.size()+colors.size()+uv.size()+uv1.size()+tangents.size()+indices.size())*4;}
    void write(NSString *path,Context &c){c.checkpoint(true,bytes());std::unique_ptr<FILE,decltype(&fclose)> f(fopen(path.fileSystemRepresentation,"wb"),&fclose);if(!f)throw Failure(2,"无法写入几何缓存。");
        uint32_t header[8]={0x3144334f,3,uint32_t(indices.size()),uint32_t(indices.size()),0,uint32_t(hasColors),uint32_t(hasUV)|(uint32_t(hasUV1)<<1),uint32_t(hasTangents)};
        auto append=[&](const void *p,size_t n){if(n&&fwrite(p,1,n,f.get())!=n)throw Failure(2,"几何缓存写入失败。");};
        append(header,32);for(const auto *v:{&positions,&normals})append(v->data(),v->size()*4);append(indices.data(),indices.size()*4);
        for(const auto *v:{&colors,&uv,&uv1,&tangents})append(v->data(),v->size()*4);if(fflush(f.get()))throw Failure(2,"几何缓存写入失败。");}
};
M World(const cgltf_node *node){std::vector<const cgltf_node *> chain;for(auto n=node;n;n=n->parent){if(chain.size()>=512||std::find(chain.begin(),chain.end(),n)!=chain.end())throw Failure(1,"模型节点层级循环或过深。");chain.push_back(n);}M m=Identity();for(auto n=chain.rbegin();n!=chain.rend();n++){float local[16];cgltf_node_transform_local(*n,local);M l;std::copy(local,local+16,l.begin());for(double x:l)if(!std::isfinite(x))throw Failure(1,"节点变换包含无效数值。");m=Multiply(m,l);}return m;}
struct Geometry {__strong NSMutableArray *chunks=[NSMutableArray array];uint64_t triangles=0,lines=0,points=0;};
class DracoPrimitive {
    Context &c_;
    std::shared_ptr<o3dv::DracoBudget> budget_;
    o3dv::DracoBudgetScope scope_;
    std::unique_ptr<draco::Mesh> mesh_;
    o3dv::DracoVector<uint32_t> strip_;
    std::unordered_map<const cgltf_accessor *,draco::PointAttribute *> attributes_;
    Clock::time_point lastReport_={};size_t reportedPeak_=0;
public:
    DracoPrimitive(const cgltf_primitive &p,Context &c):c_(c),budget_(std::make_shared<o3dv::DracoBudget>()),scope_(budget_) {
        budget_->limit=c.dracoBudgetBytes;
        auto cancel=c.cancel;
        budget_->workspace=std::make_shared<o3dv::MappedWorkspace>(c.directory.fileSystemRepresentation,[cancel]{return bool(cancel.cancelled);});
        if(o3dv::MemoryPressure().load()>0)budget_->limit=std::min(budget_->limit,size_t(64*MiB));
        if(c.cancel.decoderBudgetBytes)budget_->limit=std::min(budget_->limit,size_t(c.cancel.decoderBudgetBytes));
        budget_->checkpoint=[this] {
            if(!budget_->workspace->checkpoint())throw std::bad_alloc();
            c_.checkpoint();
            if(o3dv::MemoryPressure().load()>0)budget_->limit=std::min(budget_->limit,size_t(64*MiB));
            if(budget_->live+budget_->external>budget_->limit){budget_->limited=true;throw std::bad_alloc();}
            if(Clock::now()-lastReport_>std::chrono::milliseconds(150) || budget_->peak-reportedPeak_>=4*MiB)report();
        };
        const auto &extension=p.draco_mesh_compression;
        if(!extension.buffer_view || !extension.buffer_view->size)throw Failure(1,"Draco 缺少完整的压缩数据。");
        if(p.type!=cgltf_primitive_type_triangles && p.type!=cgltf_primitive_type_triangle_strip)throw Failure(1,"Draco 扩展只支持三角形或三角形条带。");
        report();
        draco::DecoderBuffer input;input.Init(reinterpret_cast<const char *>(cgltf_buffer_view_data(extension.buffer_view)),extension.buffer_view->size);
        draco::Decoder decoder;
        try {
            auto result=decoder.DecodeMeshFromBuffer(&input);c_.checkpoint();
            if(!result.ok())throw Failure(1,"Draco 压缩数据无效："+result.status().error_msg_string());
            mesh_=std::move(result).value();
            if(!mesh_ || mesh_->num_points()==0 || mesh_->num_faces()==0)throw Failure(1,"Draco 数据没有可显示的三角面。");
            for(size_t i=0;i<extension.attributes_count;i++) {
                const auto &a=extension.attributes[i];const cgltf_accessor *accessor=nullptr;
                for(size_t j=0;j<p.attributes_count;j++)if(!strcmp(a.name,p.attributes[j].name)){accessor=p.attributes[j].data;break;}
                if(!accessor || accessor->count!=mesh_->num_points() || accessor->is_sparse)throw Failure(1,"Draco 属性与 glTF accessor 声明不一致。");
                int attributeID=mesh_->GetAttributeIdByUniqueId(uint32_t(a.draco_id));
                auto *attribute=attributeID>=0?mesh_->attribute(attributeID):nullptr;
                if(!attribute || attribute->num_components()!=cgltf_num_components(accessor->type))throw Failure(1,"Draco 属性 ID 缺失或分量数量不一致。");
                draco::DataType expected=draco::DT_INVALID;
                switch(accessor->component_type){
                    case cgltf_component_type_r_8:expected=draco::DT_INT8;break;case cgltf_component_type_r_8u:expected=draco::DT_UINT8;break;
                    case cgltf_component_type_r_16:expected=draco::DT_INT16;break;case cgltf_component_type_r_16u:expected=draco::DT_UINT16;break;
                    case cgltf_component_type_r_32u:expected=draco::DT_UINT32;break;case cgltf_component_type_r_32f:expected=draco::DT_FLOAT32;break;
                    default:break;
                }
                if(attribute->data_type()!=expected)throw Failure(1,"Draco 属性类型与 glTF accessor 声明不一致。");
                attribute->set_normalized(accessor->normalized);
                if(!attribute->is_mapping_identity() && attribute->indices_map_size()<mesh_->num_points())throw Failure(1,"Draco 顶点映射不完整。");
                if(!attributes_.emplace(accessor,attribute).second)throw Failure(1,"Draco 属性映射重复。");
            }
            if(!attributes_.count(Attribute(p,cgltf_attribute_type_position)))throw Failure(1,"Draco 扩展缺少 POSITION 属性。");
            if(p.type==cgltf_primitive_type_triangle_strip){draco::MeshStripifier stripifier;
                if(!stripifier.GenerateTriangleStripsWithDegenerateTriangles(*mesh_,std::back_inserter(strip_)))throw Failure(1,"无法还原 Draco 三角形条带。");}
            if(p.indices && p.indices->count!=count())throw Failure(1,"Draco 索引数量与 glTF accessor 声明不一致。");
            if(!budget_->workspace->checkpoint(true))throw std::bad_alloc();
            c_.dracoMeshCount++;report();
        } catch(const std::bad_alloc &) {
            c_.dracoPeakBytes=std::max(c_.dracoPeakBytes,budget_->peak);
            c_.checkpoint();
            if(budget_->workspace->failure==o3dv::MappedWorkspace::Failure::disk)throw Failure(2,"设备存储空间不足以保存 Draco 解码工作数据，请清理存储后重试。");
            throw Failure(2,"单个 Draco 压缩网格的解码资源超过当前设备预算，已停止加载；没有减少模型几何。");
        }
    }
    ~DracoPrimitive(){c_.dracoPeakBytes=std::max(c_.dracoPeakBytes,budget_->peak);c_.dracoWorkspaceBytes=std::max(c_.dracoWorkspaceBytes,budget_->workspace->diskBytes);budget_->checkpoint=nullptr;}
    void report() {
        c_.dracoPeakBytes=std::max(c_.dracoPeakBytes,budget_->peak);lastReport_=Clock::now();reportedPeak_=budget_->peak;
        @autoreleasepool {c_.progress(@{@"phase":@"decoding",@"objects":@(c_.sourceObjects),@"bytesRead":@(uint64_t(c_.sourceBytes*std::min(1.0,double(c_.work)/c_.totalWork))),
            @"sourceBytes":@(c_.sourceBytes),@"decoderAllocationBytes":@(budget_->live+budget_->external),@"decoderBudgetBytes":@(budget_->limit)});}
        c_.checkpoint();
    }
    size_t count()const{return strip_.empty()?size_t(mesh_->num_faces())*3:strip_.size();}
    size_t index(size_t corner)const {
        if(corner>=count())throw Failure(1,"Draco 三角面索引越界。");
        size_t point=strip_.empty()?mesh_->face(draco::FaceIndex(uint32_t(corner/3)))[corner%3].value():strip_[corner];
        if(point>=mesh_->num_points())throw Failure(1,"Draco 顶点索引超出数据范围。");return point;
    }
    bool read(const cgltf_accessor *accessor,size_t point,float *out,size_t components) {
        auto found=attributes_.find(accessor);if(found==attributes_.end())return false;
        if(point>=mesh_->num_points())throw Failure(1,"Draco 属性顶点越界。");
        auto *a=found->second;auto index=a->mapped_index(draco::PointIndex(uint32_t(point)));
        if(index.value()>=a->size() || !a->ConvertValue<float>(index,int8_t(components),out))throw Failure(1,"无法读取 Draco 属性。");
        for(size_t i=0;i<components;i++)if(!std::isfinite(out[i]))throw Failure(1,"Draco 属性包含非有限数值。");
        return true;
    }
};
}

@implementation GltfStreamReader
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory progress:(void (^)(NSDictionary<NSString *,id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    __strong NSError *operationError=nil;std::unique_lock<std::mutex> lock(o3dv::NativeReadMutex());
    @autoreleasepool {
        try {
            if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&operationError]){if(error)*error=operationError;return NO;}
            Context c{cancellation,progress,directory,source.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath};c.checkpoint(true);
            auto &file=c.map(source);c.sourceBytes=file.size;
            const auto *bytes=static_cast<const unsigned char *>(file.data);const unsigned char *json=bytes,*bin=nullptr;size_t jsonSize=file.size,binSize=0;
            if(file.size>=4 && !memcmp(bytes,"glTF",4)) {
                auto u32=[](const unsigned char *p){uint32_t n;memcpy(&n,p,4);return n;};
                if(file.size<20 || u32(bytes+4)!=2 || u32(bytes+8)!=file.size)throw Failure(1,"GLB 版本或文件长度无效。");
                size_t at=12;bool first=true;
                while(at<file.size){if(file.size-at<8)throw Failure(1,"GLB chunk 已截断。");size_t n=u32(bytes+at);uint32_t type=u32(bytes+at+4);at+=8;
                    if(n%4 || n>file.size-at)throw Failure(1,"GLB chunk 范围无效。");
                    if(first){if(type!=0x4e4f534a)throw Failure(1,"GLB 首个 chunk 必须为 JSON。");json=bytes+at;jsonSize=n;}
                    else if(type==0x004e4942){if(bin)throw Failure(1,"GLB 包含重复 BIN chunk。");bin=bytes+at;binSize=n;}
                    else if(type==0x4e4f534a)throw Failure(1,"GLB 包含重复 JSON chunk。");first=false;at+=n;
                }
            }
            if(jsonSize>MetadataLimit)throw Failure(2,"模型 JSON 元数据超过当前 64 MiB 解析预算。");
            MetadataMemory memory;cgltf_options options={};options.type=cgltf_file_type_gltf;options.memory={MetadataMemory::allocate,MetadataMemory::release,&memory};
            cgltf_data *raw=nullptr;auto parsed=cgltf_parse(&options,json,jsonSize,&raw);
            std::unique_ptr<cgltf_data,decltype(&cgltf_free)> model(raw,&cgltf_free);
            if(parsed!=cgltf_result_success)throw Failure(memory.limited?2:1,memory.limited?"模型元数据超过解析预算。":"glTF JSON 格式、版本或引用无效。");
            if(![Text(raw->asset.version) isEqual:@"2.0"])throw Failure(1,"仅支持 glTF 2.0。");
            std::set<std::string> supported={"KHR_texture_transform","KHR_mesh_quantization","KHR_materials_unlit","KHR_materials_emissive_strength","KHR_draco_mesh_compression"};
            for(size_t i=0;i<raw->extensions_required_count;i++)if(!supported.count(raw->extensions_required[i]))throw Failure(4,"当前原生读取路径尚未支持必需扩展："+std::string(raw->extensions_required[i]));
            for(size_t i=0;i<raw->buffers_count;i++) {
                c.checkpoint();auto &b=raw->buffers[i];
                if(!b.uri){if(i || !bin || b.size>binSize || binSize-b.size>3)throw Failure(1,"GLB 缺少完整 BIN 数据。");b.data=const_cast<unsigned char *>(bin);}
                else if(!strncmp(b.uri,"data:",5)){NSString *path=[directory stringByAppendingPathComponent:[NSString stringWithFormat:@".buffer-%lu",i]];[c.temporaries addObject:path];c.dataURI(b.uri,path);auto &map=c.map(path);if(map.size!=b.size)throw Failure(1,"内嵌 buffer 长度与声明不一致。");b.data=map.data;}
                else {auto &map=c.map(c.local(b.uri));if(map.size<b.size)throw Failure(1,"本地 BIN 数据已截断。");b.data=map.data;}
                b.data_free_method=cgltf_data_free_method_none;
            }
            Validate(raw,c);c.checkpoint();
            NSMutableArray *materials=[NSMutableArray array],*objects=[NSMutableArray array],*warnings=[NSMutableArray array],*nodes=[NSMutableArray array];
            std::unordered_map<const cgltf_image *,NSString *__strong> imageFiles;
            auto imageFile=[&](cgltf_image *image)->NSString * {
                if(!image)return nil;auto found=imageFiles.find(image);if(found!=imageFiles.end())return found->second;
                NSString *mime=Text(image->mime_type);
                if(!mime.length && image->uri && !strncmp(image->uri,"data:",5)) {
                    const char *end=strchr(image->uri,';');if(end)mime=[[NSString alloc] initWithBytes:image->uri+5 length:size_t(end-image->uri-5) encoding:NSUTF8StringEncoding];
                }
                NSString *ext=[mime isEqual:@"image/png"]?@"png":([mime isEqual:@"image/webp"]?@"webp":@"jpg");
                NSString *local=nil;if(image->uri && strncmp(image->uri,"data:",5)){local=c.local(image->uri,true);if(!local)return nil;ext=local.pathExtension;}
                NSString *name=[NSString stringWithFormat:@"texture-%lu.%@",size_t(image-raw->images),ext.length?ext:@"img"],*path=[directory stringByAppendingPathComponent:name];
                if(local){auto &map=c.map(local);c.write(map.data,map.size,path);}
                else if(image->buffer_view){auto *v=image->buffer_view;c.write(cgltf_buffer_view_data(v),v->size,path);}
                else if(image->uri)c.dataURI(image->uri,path);
                else throw Failure(1,"模型图片没有本地数据。");
                imageFiles.emplace(image,name);return name;
            };
            auto texture=[&](const cgltf_texture_view &view)->id {
                if(!view.texture)return NSNull.null;auto *t=view.texture;
                cgltf_image *image=t->image;if(!image && t->has_webp)image=t->webp_image;
                if(!image && t->has_basisu)throw Failure(4,"当前原生贴图路径尚未接入 KTX2 / Basis 压缩。");
                NSString *name=imageFile(image);if(!name)return NSNull.null;
                int channel=view.has_transform&&view.transform.has_texcoord?view.transform.texcoord:view.texcoord;
                if(channel<0||channel>1)throw Failure(4,"当前分块贴图路径支持 TEXCOORD_0 和 TEXCOORD_1。");
                double angle=view.has_transform?view.transform.rotation:0,cs=cos(angle),sn=sin(angle),sx=view.has_transform?view.transform.scale[0]:1,sy=view.has_transform?view.transform.scale[1]:1;
                auto *s=t->sampler;return @{@"url":name,@"flipY":@NO,@"channel":@(channel),@"scale":@(view.scale),
                    @"matrix":@[@(cs*sx),@(sn*sx),@0,@(-sn*sy),@(cs*sy),@0,@(view.has_transform?view.transform.offset[0]:0),@(view.has_transform?view.transform.offset[1]:0),@1],
                    @"wrapS":@(s?s->wrap_s:cgltf_wrap_mode_repeat),@"wrapT":@(s?s->wrap_t:cgltf_wrap_mode_repeat),
                    @"magFilter":@(s?s->mag_filter:cgltf_filter_type_linear),@"minFilter":@(s?s->min_filter:cgltf_filter_type_linear)};
            };
            for(size_t i=0;i<raw->materials_count;i++) {
                @autoreleasepool {
                    auto &m=raw->materials[i];auto &p=m.pbr_metallic_roughness;
                    if(m.has_pbr_specular_glossiness)throw Failure(4,"当前原生材质路径尚未接入 specular-glossiness 材质扩展。");
                    if(m.has_clearcoat||m.has_transmission||m.has_volume||m.has_specular||m.has_sheen||m.has_iridescence||m.has_anisotropy||m.has_diffuse_transmission||m.has_dispersion)
                        [warnings addObject:[NSString stringWithFormat:@"材质 %@ 的扩展参数尚未显示，基础 PBR 保留",Text(m.name)]];
                    NSString *alpha=m.alpha_mode==cgltf_alpha_mode_blend?@"BLEND":m.alpha_mode==cgltf_alpha_mode_mask?@"MASK":@"OPAQUE";
                    [materials addObject:@{@"index":@(i),@"name":Text(m.name),@"shading":m.unlit?@"unlit":@"pbr",@"color":@[@(p.base_color_factor[0]),@(p.base_color_factor[1]),@(p.base_color_factor[2])],
                        @"opacity":@(m.alpha_mode==cgltf_alpha_mode_opaque?1:p.base_color_factor[3]),@"metalness":@(p.metallic_factor),@"roughness":@(p.roughness_factor),@"alphaMode":alpha,@"alphaCutoff":@(m.alpha_cutoff),@"doubleSided":@(m.double_sided),
                        @"emissive":@[@(m.emissive_factor[0]),@(m.emissive_factor[1]),@(m.emissive_factor[2])],@"emissiveIntensity":@(m.has_emissive_strength?m.emissive_strength.emissive_strength:1),
                        @"texture":texture(p.base_color_texture),@"normalTexture":texture(m.normal_texture),@"metallicRoughnessTexture":texture(p.metallic_roughness_texture),
                        @"occlusionTexture":texture(m.occlusion_texture),@"emissiveTexture":texture(m.emissive_texture),@"normalScale":@(m.normal_texture.scale),@"occlusionStrength":@(m.occlusion_texture.scale)}];
                }
            }
            // The glTF default material is white, fully metallic and fully rough.
            [materials addObject:@{@"index":@(-1),@"name":@"默认材质",@"shading":@"pbr",@"color":@[@1,@1,@1],@"opacity":@1,@"metalness":@1,@"roughness":@1,@"alphaMode":@"OPAQUE",@"doubleSided":@NO}];
            std::vector<const cgltf_node *> placements;std::set<const cgltf_node *> visited;
            auto walk=[&](auto &&self,const cgltf_node *n,size_t depth)->void {
                c.checkpoint();if(depth>=512 || !visited.insert(n).second)throw Failure(1,"模型场景存在重复节点或循环引用。");
                size_t index=size_t(n-raw->nodes);[nodes addObject:@{@"index":@(index),@"name":Text(n->name),@"parent":n->parent?@(n->parent-raw->nodes):@(-1),@"matrix":JSON(World(n)),@"mesh":n->mesh?@(n->mesh-raw->meshes):@(-1)}];
                if(n->has_mesh_gpu_instancing)throw Failure(4,"当前原生路径尚未接入 EXT_mesh_gpu_instancing。");
                if(n->mesh){placements.push_back(n);for(size_t i=0;i<n->mesh->primitives_count;i++){auto &p=n->mesh->primitives[i];auto a=Attribute(p,cgltf_attribute_type_position);if(!a)throw Failure(1,"网格缺少 POSITION。");c.totalWork+=p.indices?p.indices->count:a->count;}}
                for(size_t i=0;i<n->children_count;i++)self(self,n->children[i],depth+1);
            };
            auto *scene=raw->scene?raw->scene:(raw->scenes_count?&raw->scenes[0]:nullptr);
            if(scene){for(size_t i=0;i<scene->nodes_count;i++)walk(walk,scene->nodes[i],0);}
            else for(size_t i=0;i<raw->nodes_count;i++)if(!raw->nodes[i].parent)walk(walk,&raw->nodes[i],0);
            if(placements.empty())throw Failure(1,"所选场景没有可显示的网格。");
            c.sourceObjects=placements.size();Box worldBounds;size_t fileNumber=0;
            NSMutableDictionary *manifest=[@{@"format":@"o3dv-stream-1",@"reader":@"gltf-stream-1",@"name":source.lastPathComponent,@"sourceBytes":@(file.size),
                @"layers":@[@{@"id":@"model",@"index":@0,@"name":@"模型",@"visible":@YES}],@"materials":materials,@"objects":objects,@"nodes":nodes,
                @"unsupported":@[],@"warnings":warnings,@"missingFiles":c.missing,@"complete":@NO,@"sourceObjectCount":@(placements.size()),@"animationCount":@(raw->animations_count),@"pose":@"default"} mutableCopy];
            bool published=false;
            auto publish=[&](NSString *phase){@autoreleasepool {
                c.checkpoint(true,objects.count*4096+16384);
                [manifest addEntriesFromDictionary:@{@"objectCount":@(objects.count),@"geometryBytes":@(c.geometryBytes),@"triangles":@(c.triangles),@"sourceTriangles":@(c.triangles),@"lineSegments":@(c.lines),@"points":@(c.points),@"vertices":@(c.work),
                    @"bounds":worldBounds.json(),@"nativePeakFootprintBytes":@(c.peakFootprint),@"nativePeakMemoryBytes":@(c.peakResident),@"metadataPeakBytes":@(memory.peak),
                    @"dracoDecodedPrimitiveCount":@(c.dracoMeshCount),@"dracoPeakAllocationBytes":@(c.dracoPeakBytes),@"dracoDecoderBudgetBytes":@(c.dracoBudgetBytes),@"dracoWorkspaceDiskBytes":@(c.dracoWorkspaceBytes)}];
                NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&operationError];
                if(!data||![data writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&operationError])throw Failure(2,"无法写入 glTF 模型清单。");
                double fraction=std::min(1.0,double(c.work)/c.totalWork);if([phase isEqual:@"complete"])fraction=1;
                progress(@{@"phase":phase,@"objects":@(placements.size()),@"bytesRead":@(uint64_t(c.sourceBytes*fraction)),@"sourceBytes":@(c.sourceBytes),@"fraction":@(fraction)});
                c.lastPublish=Clock::now();published=true;
            }};
            std::unordered_map<std::string,Geometry> geometries;
            const M axis={1,0,0,0,0,0,1,0,0,-1,0,0,0,0,0,1};
            for(auto *node:placements) {
                @autoreleasepool {
                    M world=World(node),placement=Multiply(axis,world);auto *mesh=node->mesh;
                    std::vector<double> weights(mesh->primitives_count?mesh->primitives[0].targets_count:0,0);
                    const float *sourceWeights=node->weights?node->weights:mesh->weights;size_t weightCount=node->weights?node->weights_count:mesh->weights_count;
                    if(sourceWeights){if(weightCount!=weights.size())throw Failure(1,"形变目标权重数量不一致。");std::copy(sourceWeights,sourceWeights+weightCount,weights.begin());}
                    std::vector<M> skin;
                    if(node->skin){auto inverse=Inverse(world);for(size_t j=0;j<node->skin->joints_count;j++) {M bind=Identity();if(node->skin->inverse_bind_matrices){float values[16];Read(node->skin->inverse_bind_matrices,j,values,16);std::copy(values,values+16,bind.begin());}skin.push_back(Multiply(Multiply(inverse,World(node->skin->joints[j])),bind));}}
                    for(size_t primitiveIndex=0;primitiveIndex<mesh->primitives_count;primitiveIndex++) {
                        auto &p=mesh->primitives[primitiveIndex];
                        auto positions=Attribute(p,cgltf_attribute_type_position),normals=Attribute(p,cgltf_attribute_type_normal),colors=Attribute(p,cgltf_attribute_type_color),uv=Attribute(p,cgltf_attribute_type_texcoord),uv1=Attribute(p,cgltf_attribute_type_texcoord,1),tangents=Attribute(p,cgltf_attribute_type_tangent);
                        if(!positions||positions->type!=cgltf_type_vec3)throw Failure(1,"POSITION 必须是 VEC3。");
                        for(size_t a=0;a<p.attributes_count;a++)if(p.attributes[a].data->count!=positions->count)throw Failure(1,"同一网格的顶点属性数量不一致。");
                        if((normals&&normals->type!=cgltf_type_vec3)||(colors&&colors->type!=cgltf_type_vec3&&colors->type!=cgltf_type_vec4)||(uv&&uv->type!=cgltf_type_vec2)||(uv1&&uv1->type!=cgltf_type_vec2)||(tangents&&tangents->type!=cgltf_type_vec4))throw Failure(1,"顶点属性类型无效。");
                        if(p.indices&&(p.indices->type!=cgltf_type_scalar || !(p.indices->component_type==cgltf_component_type_r_8u||p.indices->component_type==cgltf_component_type_r_16u||p.indices->component_type==cgltf_component_type_r_32u)))throw Failure(1,"索引 accessor 类型无效。");
                        size_t count=p.indices?p.indices->count:positions->count;std::string key=std::to_string(size_t(mesh-raw->meshes))+":"+std::to_string(primitiveIndex);
                        if(node->skin)key+=":skin-node:"+std::to_string(size_t(node-raw->nodes));
                        for(double weight:weights){if(!std::isfinite(weight))throw Failure(1,"形变权重无效。");key.append(reinterpret_cast<const char *>(&weight),sizeof(weight));}
                        int material=p.material?int(p.material-raw->materials):-1;NSDictionary *mat=materials[material>=0?material:materials.count-1];
                        for(NSString *slot in @[@"texture",@"normalTexture",@"metallicRoughnessTexture",@"occlusionTexture",@"emissiveTexture"])
                            if([mat[slot] isKindOfClass:NSDictionary.class] && !([mat[slot][@"channel"] intValue]==1?uv1:uv))throw Failure(1,"材质引用的纹理坐标在网格中缺失。");
                        NSString *nodeID=[NSString stringWithFormat:@"node-%lu",size_t(node-raw->nodes)],*name=Text(node->name);if(!name.length)name=Text(mesh->name);if(!name.length)name=@"模型";
                        auto placeChunk=[&](NSDictionary *part){NSMutableDictionary *item=[part mutableCopy];NSArray *b=part[@"geometryBounds"];Box local;local.add(V{[b[0] doubleValue],[b[1] doubleValue],[b[2] doubleValue]});local.add(V{[b[3] doubleValue],[b[4] doubleValue],[b[5] doubleValue]});auto placed=local.placed(placement);worldBounds.add(placed);
                            [item addEntriesFromDictionary:@{@"id":[NSString stringWithFormat:@"placed-%lu",objects.count],@"index":@(objects.count),@"name":name,@"type":@"Mesh",@"layerIndex":@0,@"materialIndex":@(material),@"color":mat[@"color"],@"opacity":mat[@"opacity"],@"alphaMode":mat[@"alphaMode"],
                                @"lineColor":mat[@"color"],@"visible":@YES,@"definitionMember":@NO,@"available":@YES,@"transform":JSON(placement),@"bounds":placed.json(),@"sourceNode":@(node-raw->nodes),@"sourceMesh":@(mesh-raw->meshes),@"primitiveIndex":@(primitiveIndex),
                                @"triangles":[part[@"drawMode"] isEqual:@"triangles"]?@([part[@"count"] unsignedLongLongValue]/3):@0,@"lineSegments":[part[@"drawMode"] isEqual:@"lines"]?@([part[@"count"] unsignedLongLongValue]/2):@0,
                                @"parts":@[@{@"id":nodeID,@"name":name,@"type":@"Mesh",@"start":@0,@"end":part[@"count"],@"lineStart":@0,@"lineEnd":@0}]}];[objects addObject:item];
                            uint64_t count=[part[@"count"] unsignedLongLongValue];
                            if([part[@"drawMode"] isEqual:@"triangles"])c.triangles+=count/3;else if([part[@"drawMode"] isEqual:@"lines"])c.lines+=count/2;else c.points+=count;
                            c.work+=count;
                            if(!published||Clock::now()-c.lastPublish>std::chrono::milliseconds(200))publish(published?@"parsing":@"ready");
                        };

                        auto found=geometries.find(key);
                        if(found==geometries.end()) {
                            std::unique_ptr<DracoPrimitive> draco;
                            if(p.has_draco_mesh_compression){draco=std::make_unique<DracoPrimitive>(p,c);count=draco->count();}
                            auto read=[&](const cgltf_accessor *a,size_t index,float *out,size_t components){if(!draco || !draco->read(a,index,out,components))Read(a,index,out,components);};
                            Geometry geometry;Chunk chunk;chunk.hasColors=colors;chunk.hasUV=uv;chunk.hasUV1=uv1;chunk.hasTangents=tangents;
                            NSString *mode=p.type==cgltf_primitive_type_points?@"points":(p.type==cgltf_primitive_type_lines||p.type==cgltf_primitive_type_line_loop||p.type==cgltf_primitive_type_line_strip)?@"lines":@"triangles";
                            int width=[mode isEqual:@"points"]?1:[mode isEqual:@"lines"]?2:3;
                            auto flush=[&](){if(chunk.indices.empty())return;@autoreleasepool {
                                NSString *name=[NSString stringWithFormat:@"geometry-%06lu.bin",fileNumber++];chunk.write([directory stringByAppendingPathComponent:name],c);c.geometryBytes+=chunk.bytes();
                                [geometry.chunks addObject:@{@"url":name,@"bytes":@(chunk.bytes()),@"geometryBounds":chunk.bounds.json(),@"origin":@[@(chunk.origin[0]),@(chunk.origin[1]),@(chunk.origin[2])],@"vertices":@(chunk.indices.size()),@"count":@(chunk.indices.size()),@"drawMode":mode}];placeChunk(geometry.chunks.lastObject);
                                chunk.positions.clear();chunk.normals.clear();chunk.indices.clear();chunk.colors.clear();chunk.uv.clear();chunk.uv1.clear();chunk.tangents.clear();chunk.bounds=Box();
                            }};
                            auto vertex=[&](size_t corner)->Vertex {
                                if(corner>=count)throw Failure(1,"图元索引越界。");size_t index=corner;
                                if(draco)index=draco->index(corner);else if(p.indices)index=ReadIndex(p.indices,corner);
                                Vertex v;float values[4]={};read(positions,index,values,3);for(int k=0;k<3;k++)v.p[k]=values[k];
                                if(normals){read(normals,index,values,3);for(int k=0;k<3;k++)v.n[k]=values[k];}
                                if(colors)read(colors,index,v.color.data(),cgltf_num_components(colors->type));if(uv)read(uv,index,v.uv.data(),2);if(uv1)read(uv1,index,v.uv1.data(),2);if(tangents)read(tangents,index,v.tangent.data(),4);
                                for(size_t t=0;t<p.targets_count;t++)if(t<weights.size()&&weights[t]!=0){auto &target=p.targets[t];for(size_t a=0;a<target.attributes_count;a++){auto &attribute=target.attributes[a];float delta[3];Read(attribute.data,index,delta,3);for(int k=0;k<3;k++){if(attribute.type==cgltf_attribute_type_position)v.p[k]+=delta[k]*weights[t];else if(attribute.type==cgltf_attribute_type_normal)v.n[k]+=delta[k]*weights[t];else if(attribute.type==cgltf_attribute_type_tangent)v.tangent[k]+=delta[k]*weights[t];}}}
                                if(node->skin){M blended={};double sum=0;for(int set=0;set<2;set++){auto joints=Attribute(p,cgltf_attribute_type_joints,set),jointWeights=Attribute(p,cgltf_attribute_type_weights,set);if(!joints&&!jointWeights)continue;if(!joints||!jointWeights||joints->type!=cgltf_type_vec4||jointWeights->type!=cgltf_type_vec4)throw Failure(1,"骨骼属性不完整。");float ji[4],jw[4];read(joints,index,ji,4);read(jointWeights,index,jw,4);for(int k=0;k<4;k++){if(jw[k]<0||ji[k]<0||ji[k]>=skin.size()||ji[k]!=floor(ji[k]))throw Failure(1,"骨骼索引或权重无效。");sum+=jw[k];for(int q=0;q<16;q++)blended[q]+=skin[size_t(ji[k])][q]*jw[k];}}
                                    if(sum<=0)throw Failure(1,"骨骼权重总和必须大于零。");for(double &x:blended)x/=sum;v.p=Position(blended,v.p);if(normals)v.n=Normal(blended,v.n);
                                    if(tangents){V t={v.tangent[0],v.tangent[1],v.tangent[2]},out={};for(int r=0;r<3;r++)out[r]=blended[r]*t[0]+blended[4+r]*t[1]+blended[8+r]*t[2];out=Unit(out);for(int k=0;k<3;k++)v.tangent[k]=float(out[k]);}}
                                if(normals)v.n=Unit(v.n);return v;
                            };
                            auto emit=[&](std::initializer_list<size_t> corners){std::array<Vertex,3> vertices;size_t n=0;for(size_t corner:corners)vertices[n++]=vertex(corner);
                                if(width==3&&!normals){V u,v;for(int k=0;k<3;k++){u[k]=vertices[1].p[k]-vertices[0].p[k];v[k]=vertices[2].p[k]-vertices[0].p[k];}auto normal=Unit(Cross(Unit(u),Unit(v)));for(size_t i=0;i<n;i++)vertices[i].n=normal;}
                                for(size_t i=0;i<n;i++)chunk.add(vertices[i]);if(chunk.indices.size()>=BlockCorners)flush();
                                if((chunk.indices.size()&1023)<3)c.checkpoint();
                                if(width==3)geometry.triangles++;else if(width==2)geometry.lines++;else geometry.points++;
                            };
                            switch(p.type){
                                case cgltf_primitive_type_points:for(size_t i=0;i<count;i++)emit({i});break;
                                case cgltf_primitive_type_lines:if(count%2)throw Failure(1,"LINES 索引数量必须为偶数。");for(size_t i=0;i<count;i+=2)emit({i,i+1});break;
                                case cgltf_primitive_type_line_strip:for(size_t i=1;i<count;i++)emit({i-1,i});break;
                                case cgltf_primitive_type_line_loop:for(size_t i=1;i<count;i++)emit({i-1,i});if(count>1)emit({count-1,0});break;
                                case cgltf_primitive_type_triangles:if(count%3)throw Failure(1,"TRIANGLES 索引数量必须为三的倍数。");for(size_t i=0;i<count;i+=3)emit({i,i+1,i+2});break;
                                case cgltf_primitive_type_triangle_strip:for(size_t i=2;i<count;i++)if(i%2)emit({i-1,i-2,i});else emit({i-2,i-1,i});break;
                                case cgltf_primitive_type_triangle_fan:for(size_t i=2;i<count;i++)emit({0,i-1,i});break;
                                default:throw Failure(1,"模型包含无效图元类型。");
                            }
                            flush();found=geometries.emplace(key,std::move(geometry)).first;
                        } else for(NSDictionary *part in found->second.chunks)placeChunk(part);

                    }
                }
            }
            if(objects.count==0)throw Failure(1,"模型没有可显示的几何。");c.checkpoint();manifest[@"complete"]=@YES;publish(@"complete");return YES;
        } catch(const Failure &failure){operationError=[NSError errorWithDomain:@"O3DVGLTF" code:failure.code userInfo:@{NSLocalizedDescriptionKey:Text(failure.what())}];}
          catch(const std::bad_alloc &){operationError=[NSError errorWithDomain:@"O3DVGLTF" code:2 userInfo:@{NSLocalizedDescriptionKey:@"设备可用内存不足，已停止 glTF 读取。"}];}
          catch(const std::exception &failure){operationError=[NSError errorWithDomain:@"O3DVGLTF" code:1 userInfo:@{NSLocalizedDescriptionKey:Text(failure.what())}];}
    }
    if(error)*error=operationError;return NO;
}
@end
