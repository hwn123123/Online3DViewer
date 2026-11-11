#import "SkpStreamReader.h"
#include "NativeReadLock.hpp"
#include "SkpMemory.hpp"
#include "internal.hpp"
#include "face_groups.hpp"
#include <CommonCrypto/CommonDigest.h>
#include <cmath>
#include <cfloat>
#include <cstdio>
#include <fstream>
#include <sys/stat.h>

namespace {
using Clock=std::chrono::steady_clock;
using V=std::array<double,3>;
using M=std::array<double,16>;
constexpr size_t MiB=1024*1024,BlockCorners=24576;
struct Failure:std::runtime_error{int code;Failure(int c,const std::string&s):std::runtime_error(s),code(c){}};
NSString *Text(const std::string&s){return [[NSString alloc]initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding]?:@"";}
template<size_t N>NSArray *JSON(const std::array<double,N>&v){NSMutableArray *a=[NSMutableArray array];for(double x:v){if(!std::isfinite(x))throw Failure(1,"模型包含无效数值。");[a addObject:@(x)];}return a;}
M Identity(){return {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};}
double LinearColor(int channel){double c=std::clamp(channel/255.,0.,1.);return c<=.04045?c/12.92:std::pow((c+.055)/1.055,2.4);}
M Multiply(const M&a,const M&b){M c={};for(int col=0;col<4;col++)for(int r=0;r<4;r++)for(int k=0;k<4;k++)c[col*4+r]+=a[k*4+r]*b[col*4+k];return c;}
M Matrix(const o3dv::SkpVector<double>&raw){if(raw.empty())return Identity();if(raw.size()!=13)throw Failure(1,"SKP 组件矩阵长度无效。");auto m=openskp::fold_scale(raw);M out={m[0],m[3],m[6],0,m[1],m[4],m[7],0,m[2],m[5],m[8],0,m[9]*.0254,m[10]*.0254,m[11]*.0254,1};for(double v:out)if(!std::isfinite(v))throw Failure(1,"SKP 组件矩阵包含无效数值。");return out;}
V Position(const M&m,const V&v){V o={};for(int r=0;r<3;r++)o[r]=m[r]*v[0]+m[4+r]*v[1]+m[8+r]*v[2]+m[12+r];return o;}
struct Box {
    V lo={INFINITY,INFINITY,INFINITY},hi={-INFINITY,-INFINITY,-INFINITY};
    void add(const V&p){for(int k=0;k<3;k++){if(!std::isfinite(p[k]))throw Failure(1,"SKP 坐标无效。");lo[k]=std::min(lo[k],p[k]);hi[k]=std::max(hi[k],p[k]);}}
    void add(const Box&b){if(std::isfinite(b.lo[0])){add(b.lo);add(b.hi);}}
    Box placed(const M&m)const{Box b;for(int i=0;i<8;i++)b.add(Position(m,{(i&1)?hi[0]:lo[0],(i&2)?hi[1]:lo[1],(i&4)?hi[2]:lo[2]}));return b;}
    NSArray *json()const{return std::isfinite(lo[0])?@[@(lo[0]),@(lo[1]),@(lo[2]),@(hi[0]),@(hi[1]),@(hi[2])]:@[@0,@0,@0,@0,@0,@0];}
};
struct Context {
    __strong NSString *directory;
    __strong RhinoReadCancellation *cancel;
    __strong void (^progress)(NSDictionary *);
    std::shared_ptr<o3dv::SkpBudget> budget;
    uint64_t sourceBytes=0,geometryBytes=0,triangles=0,lines=0,sourceObjects=0,vertices=0,fileNumber=0;
    size_t peakFootprint=0,peakResident=0,reportedPeak=0;
    Clock::time_point lastCheck={},lastReport={},lastWorkspaceCheck={};
    bool parsed=false;
    void check(bool disk=false,uint64_t needed=0){
        if(cancel.cancelled)throw Failure(3,"读取已取消。");
        auto now=Clock::now();if(!disk&&now-lastCheck<std::chrono::milliseconds(100)&&o3dv::MemoryPressure().load()<2)return;lastCheck=now;
        auto m=o3dv::SampleMemory();peakFootprint=std::max(peakFootprint,m.footprint);peakResident=std::max(peakResident,m.resident);
        if(m.pressure>=2||m.footprint>512*MiB||(m.availableKnown&&m.available<32*MiB))throw Failure(2,"设备当前可用内存不足，已停止 SKP 读取。");
        if(disk){struct statvfs fs={};if(statvfs(directory.fileSystemRepresentation,&fs))throw Failure(2,"无法检查模型缓存存储空间。");uint64_t available=uint64_t(fs.f_bavail)*fs.f_frsize;if(available<512*MiB||needed>available-512*MiB)throw Failure(2,"本地空间不足，无法保存完整 SKP 缓存。");}
    }
    void report(){auto now=Clock::now();if(now-lastReport<std::chrono::milliseconds(150)&&budget->peak-reportedPeak<4*MiB)return;lastReport=now;reportedPeak=budget->peak;progress(@{@"phase":parsed?@"building":@"decoding",@"objects":@(sourceObjects),@"sourceBytes":@(sourceBytes),@"decoderAllocationBytes":@(budget->peak)});}
    void write(const void*p,size_t n,NSString*name){check(true,n);std::unique_ptr<FILE,decltype(&fclose)>f(fopen([directory stringByAppendingPathComponent:name].fileSystemRepresentation,"wb"),&fclose);if(!f)throw Failure(2,"无法创建 SKP 缓存。");for(size_t at=0;at<n;at+=65536){check();auto count=std::min(size_t(65536),n-at);if(fwrite(static_cast<const char*>(p)+at,1,count,f.get())!=count)throw Failure(2,"SKP 缓存写入失败。");}if(fflush(f.get()))throw Failure(2,"SKP 缓存写入失败。");}
};
struct Chunk {
    std::vector<float> positions,normals,uv;
    std::vector<uint32_t> indices;
    V origin={};Box box;bool line=false;
    void add(V p,V n,std::array<float,2> t={}){if(indices.empty())origin=p;box.add(p);indices.push_back(uint32_t(indices.size()));for(int k=0;k<3;k++){double value=p[k]-origin[k];if(!std::isfinite(value)||fabs(value)>FLT_MAX||!std::isfinite(n[k])||!std::isfinite(t[0])||!std::isfinite(t[1]))throw Failure(1,"SKP 顶点属性无效。");positions.push_back(float(value));if(!line)normals.push_back(float(n[k]));}if(!line){uv.push_back(t[0]);uv.push_back(t[1]);}}
    NSDictionary *flush(Context &c,int material,const std::string&layer,bool hidden){if(indices.empty())return nil;uint32_t h[8]={0x3144334f,3,line?0:uint32_t(indices.size()),line?0:uint32_t(indices.size()),line?uint32_t(indices.size()):0,0,line?0u:1u,0};
        std::vector<unsigned char> bytes(32+(positions.size()+normals.size()+uv.size()+(line?0:indices.size()))*4);memcpy(bytes.data(),h,32);size_t offset=32;
        auto append=[&](const void*p,size_t n){memcpy(bytes.data()+offset,p,n);offset+=n;};
        if(line)append(positions.data(),positions.size()*4);else{append(positions.data(),positions.size()*4);append(normals.data(),normals.size()*4);append(indices.data(),indices.size()*4);append(uv.data(),uv.size()*4);}
        NSString *name=[NSString stringWithFormat:@"geometry-%06llu.bin",c.fileNumber++];c.write(bytes.data(),bytes.size(),name);c.geometryBytes+=bytes.size();
        NSDictionary *part=@{@"url":name,@"bytes":@(bytes.size()),@"origin":JSON(origin),@"geometryBounds":box.json(),@"vertices":@(indices.size()),@"count":@(indices.size()),@"drawMode":line?@"lines":@"triangles",@"materialIndex":@(material),@"sourceLayer":Text(layer),@"sourceHidden":@(hidden)};
        positions.clear();normals.clear();indices.clear();uv.clear();box=Box();return part;
    }
};
}

@implementation SkpStreamReader
+(BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory progress:(void (^)(NSDictionary<NSString *,id> *))progress cancellation:(RhinoReadCancellation *)cancel error:(NSError **)error {
    std::unique_lock<std::mutex>lock(o3dv::NativeReadMutex());NSError *operationError=nil;
    @autoreleasepool {
        Context c{directory,cancel,progress};
        try {
            if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&operationError])throw Failure(2,"无法创建 SKP 缓存目录。");
            c.budget=std::make_shared<o3dv::SkpBudget>();c.budget->workspace=std::make_shared<o3dv::MappedWorkspace>(directory.fileSystemRepresentation,[cancel]{return bool(cancel.cancelled);});
            if(cancel.decoderBudgetBytes)c.budget->limit=std::min(c.budget->limit,size_t(cancel.decoderBudgetBytes));
            c.budget->checkpoint=[&]{c.check();auto now=Clock::now();if(now-c.lastWorkspaceCheck>std::chrono::milliseconds(100)){c.lastWorkspaceCheck=now;if(!c.budget->workspace->checkpoint())throw Failure(cancel.cancelled?3:2,"SKP 本地工作区资源不足，已停止读取。");}c.report();};
            o3dv::SkpBudgetScope scope(c.budget);
            struct stat st={};if(stat(source.fileSystemRepresentation,&st)||st.st_size<=0)throw Failure(1,"SKP 文件不存在或为空。");c.sourceBytes=uint64_t(st.st_size);c.check(true,c.sourceBytes);
            openskp::ByteBuffer bytes;bytes.resize(size_t(c.sourceBytes));std::ifstream in(source.fileSystemRepresentation,std::ios::binary);if(!in)throw Failure(1,"无法读取 SKP 文件。");
            for(size_t at=0;at<bytes.size();at+=MiB){c.check();auto n=std::min(MiB,bytes.size()-at);if(!in.read(reinterpret_cast<char*>(bytes.data()+at),n))throw Failure(1,"SKP 文件已截断。");c.report();}
            openskp::ParseOptions options;options.progress=[&](const auto&){c.check();c.report();};
            auto model=openskp::full_parse(bytes,options);bytes.clear();bytes.shrink_to_fit();c.parsed=true;c.check();
            openskp::FaceColorKey defaultFace={217,217,217,255};for(const auto &style:model.styles)if((style.active||style.working_copy)&&style.front_color){for(int k=0;k<3;k++)defaultFace[k]=(*style.front_color)[k];break;}
            NSMutableArray *objects=[NSMutableArray array],*layers=[NSMutableArray array],*materials=[NSMutableArray array],*nodes=[NSMutableArray array],*unsupported=[NSMutableArray array],*warnings=[NSMutableArray array];
            NSMutableDictionary *manifest=[@{@"format":@"o3dv-stream-1",@"reader":@"skp-stream-1",@"name":source.lastPathComponent,@"sourceBytes":@(c.sourceBytes),@"sketchupVersion":Text(model.version),@"units":@"metres",@"layers":layers,@"materials":materials,@"objects":objects,@"nodes":nodes,@"unsupported":unsupported,@"warnings":warnings,@"missingFiles":@[],@"complete":@NO}mutableCopy];
            std::map<std::string,int> layerIndices;auto layer=[&](std::string name){if(name.empty())name="Layer0";auto found=layerIndices.find(name);if(found!=layerIndices.end())return found->second;int index=int(layers.count);layerIndices[name]=index;bool hidden=model.layer_hidden.count(name)?model.layer_hidden.at(name):false;[layers addObject:@{@"id":Text(name),@"index":@(index),@"name":Text(name),@"visible":@(!hidden)}];return index;};
            for(const auto &name:model.layer_order)layer(name);layer("Layer0");
            std::map<std::string,size_t> textureIDs;std::unordered_map<const openskp::RawMaterial*,size_t> materialTextureIDs;std::vector<NSString *__strong> textureFiles;
            auto texture=[&](const std::shared_ptr<openskp::RawMaterial>&mat)->std::optional<size_t>{if(!mat||!mat->texture||!mat->texture->data||mat->texture->data->empty())return {};auto cached=materialTextureIDs.find(mat.get());if(cached!=materialTextureIDs.end())return cached->second;const auto &data=*mat->texture->data;unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_CTX hash;CC_SHA256_Init(&hash);for(size_t at=0;at<data.size();at+=MiB){c.check();CC_SHA256_Update(&hash,data.data()+at,CC_LONG(std::min(MiB,data.size()-at)));}CC_SHA256_Final(digest,&hash);std::string key;char hex[3];for(unsigned char b:digest){snprintf(hex,sizeof(hex),"%02x",b);key+=hex;}auto found=textureIDs.find(key);if(found!=textureIDs.end()){materialTextureIDs[mat.get()]=found->second;return found->second;}
                auto mime=openskp::sniff_image_mime(data);NSString *ext=mime&&*mime=="image/png"?@"png":mime&&*mime=="image/jpeg"?@"jpg":@"img";size_t id=textureFiles.size();NSString *name=[NSString stringWithFormat:@"texture-%lu.%@",id,ext];c.write(data.data(),data.size(),name);textureFiles.push_back(name);textureIDs[key]=id;materialTextureIDs[mat.get()]=id;return id;};
            std::map<openskp::GroupKey,int> materialIDs;auto material=[&](const openskp::GroupKey&key){auto found=materialIDs.find(key);if(found!=materialIDs.end())return found->second;int index=int(materials.count);materialIDs[key]=index;NSMutableDictionary *m=[@{@"index":@(index),@"name":[NSString stringWithFormat:@"材质 %d",index+1],@"shading":@"pbr",@"color":@[@(LinearColor(key.color[0])),@(LinearColor(key.color[1])),@(LinearColor(key.color[2]))],@"opacity":@(key.color[3]/255.),@"metalness":@0,@"roughness":@0.8,@"alphaMode":key.color[3]<255?@"BLEND":@"OPAQUE",@"doubleSided":@(key.double_sided)}mutableCopy];if(key.texture_index)m[@"texture"]=@{@"url":textureFiles.at(*key.texture_index),@"flipY":@NO,@"wrapS":@10497,@"wrapT":@10497,@"matrix":@[@1,@0,@0,@0,@1,@0,@0,@0,@1]};[materials addObject:m];return index;};
            std::map<std::string,NSMutableArray *__strong> resources;Box worldBounds;bool published=false;Clock::time_point lastPublish={};
            auto publish=[&](NSString *phase){@autoreleasepool{c.check(true,objects.count*4096+16384);[manifest addEntriesFromDictionary:@{@"objectCount":@(objects.count),@"sourceObjectCount":@(c.sourceObjects),@"geometryBytes":@(c.geometryBytes),@"triangles":@(c.triangles),@"lineSegments":@(c.lines),@"vertices":@(c.vertices),@"bounds":worldBounds.json(),@"nativePeakMemoryBytes":@(c.peakResident),@"nativePeakFootprintBytes":@(c.peakFootprint),@"skpPeakAllocationBytes":@(c.budget->peak),@"skpWorkspaceDiskBytes":@(c.budget->workspace->diskBytes)}];NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&operationError];if(!data||![data writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&operationError])throw Failure(2,"无法写入 SKP 模型清单。");progress(@{@"phase":phase,@"objects":@(c.sourceObjects),@"sourceBytes":@(c.sourceBytes)});lastPublish=Clock::now();published=true;}};
            auto resolveLayer=[&](const std::string&raw,const std::string&parent){if(raw.empty())return parent;auto found=model.layer_id_to_name.end();try{found=model.layer_id_to_name.find(std::stoll(raw));}catch(const std::exception&){}std::string name=found!=model.layer_id_to_name.end()?found->second:raw;return name=="Layer0"?parent:name;};
            std::set<openskp::EntityId> active;
            auto walk=[&](auto&&self,const openskp::GeometryBuilder&builder,std::optional<openskp::EntityId>defID,const M&world,const std::string&name,const std::string&effectiveLayer,const std::shared_ptr<openskp::RawMaterial>&paint,bool visible,NSArray *parentLayers,NSString *parentID,size_t depth)->void {
                @autoreleasepool {
                    c.check();if(depth>256)throw Failure(1,"SKP 组件嵌套过深。");NSString *nodeID=[NSString stringWithFormat:@"node-%lu",nodes.count];int layerIndex=layer(effectiveLayer);NSMutableArray *visibilityLayers=[parentLayers mutableCopy];if(![visibilityLayers containsObject:@(layerIndex)])[visibilityLayers addObject:@(layerIndex)];
                    [nodes addObject:@{@"id":nodeID,@"name":Text(name),@"parent":parentID?:@"",@"matrix":JSON(world),@"layerIndex":@(layerIndex),@"visible":@(visible)}];
                    bool hasGeometry=!builder.faces.empty()||!builder.edges.empty();if(hasGeometry)c.sourceObjects++;
                    std::string key=(defID?std::to_string(*defID):"root")+"|"+effectiveLayer+"|"+std::to_string(reinterpret_cast<uintptr_t>(paint.get()));
                    auto found=resources.find(key);
                    if(hasGeometry&&found==resources.end()){
                        NSMutableArray *parts=[NSMutableArray array];auto fallback=openskp::material_color(paint).value_or(defaultFace);
                        auto groups=openskp::build_local_face_groups(model,builder,openskp::FaceGroupContext{texture,fallback,paint});
                        for(auto &item:groups){c.check();auto &g=item.second;int mat=material(item.first);Chunk chunk;
                            o3dv::SkpVector<V> normals(g.verts.size());for(const auto &entry:g.map){auto n=g.normals.at(entry.first);double length=std::hypot(n[0],n[1],n[2]);if(length>1e-12)for(double &v:n)v/=length;else n={0,0,1};normals.at(entry.second)=n;}
                            for(auto &tri:g.tris){for(auto index:tri){if(index>=g.verts.size()||index>=g.uvs.size())throw Failure(1,"SKP 三角形索引无效。");const auto &pos=g.verts[index];chunk.add({pos[0]*.0254,pos[1]*.0254,pos[2]*.0254},normals[index],g.uvs[index]);}if(chunk.indices.size()>=BlockCorners){[parts addObject:chunk.flush(c,mat,item.first.layer,item.first.hidden)];}if((chunk.indices.size()&1023)<3)c.check();}
                            if(auto part=chunk.flush(c,mat,item.first.layer,item.first.hidden))[parts addObject:part];
                        }
                        // Only independent edges: edges bounding faces already survive as surfaces.
                        std::set<openskp::EntityId> faceEdges;for(const auto &face:builder.faces)for(const auto &loop:face.second.loops)for(const auto &co:loop)faceEdges.insert(co.edge_id);
                        std::map<bool,Chunk> lineChunks;int lineMat=material(openskp::GroupKey{fallback,true,{}});
                        for(const auto &edge:builder.edges){if(faceEdges.count(edge.first))continue;if(!edge.second.first||!edge.second.second)throw Failure(1,"SKP 线条缺少端点。");auto a=builder.vertices.find(*edge.second.first),b=builder.vertices.find(*edge.second.second);if(a==builder.vertices.end()||b==builder.vertices.end())throw Failure(1,"SKP 线条引用无效顶点。");bool hidden=builder.edge_flags.count(edge.first)&&(builder.edge_flags.at(edge.first)&openskp::kDrawHidden);auto &chunk=lineChunks[hidden];chunk.line=true;for(const auto *v:{&a->second,&b->second})chunk.add({(*v)[0]*.0254,(*v)[1]*.0254,(*v)[2]*.0254},{0,0,1});if(chunk.indices.size()>=BlockCorners)[parts addObject:chunk.flush(c,lineMat,"",hidden)];}
                        for(auto &chunk:lineChunks)if(auto part=chunk.second.flush(c,lineMat,"",chunk.first))[parts addObject:part];
                        found=resources.emplace(key,parts).first;
                    }
                    if(hasGeometry)for(NSDictionary *part:found->second){auto bounds=part[@"geometryBounds"];Box local;local.add(V{[bounds[0]doubleValue],[bounds[1]doubleValue],[bounds[2]doubleValue]});local.add(V{[bounds[3]doubleValue],[bounds[4]doubleValue],[bounds[5]doubleValue]});Box placed=local.placed(world);worldBounds.add(placed);auto mat=materials[[part[@"materialIndex"]unsignedIntegerValue]];int faceLayer=layer(resolveLayer(std::string([part[@"sourceLayer"]UTF8String]),effectiveLayer));NSMutableArray *allLayers=[visibilityLayers mutableCopy];if(![allLayers containsObject:@(faceLayer)])[allLayers addObject:@(faceLayer)];NSMutableDictionary *obj=[part mutableCopy];
                        [obj addEntriesFromDictionary:@{@"id":[NSString stringWithFormat:@"placed-%lu",objects.count],@"index":@(objects.count),@"name":Text(name),@"type":[part[@"drawMode"]isEqual:@"lines"]?@"Curve":@"Mesh",@"layerIndex":@(faceLayer),@"visibilityLayers":allLayers,@"color":mat[@"color"],@"lineColor":mat[@"color"],@"opacity":mat[@"opacity"],@"alphaMode":mat[@"alphaMode"],@"visible":@(visible&&![part[@"sourceHidden"]boolValue]),@"definitionMember":@NO,@"available":@YES,@"transform":JSON(world),@"bounds":placed.json(),@"parts":@[@{@"id":nodeID,@"name":Text(name),@"type":@"SKP",@"start":@0,@"end":part[@"count"],@"lineStart":@0,@"lineEnd":@0}]}];[objects addObject:obj];uint64_t n=[part[@"count"]unsignedLongLongValue];if([part[@"drawMode"]isEqual:@"lines"])c.lines+=n/2;else c.triangles+=n/3;c.vertices+=n;
                    }
                    if(objects.count&&(!published||Clock::now()-lastPublish>std::chrono::milliseconds(750)))publish(published?@"building":@"ready");
                    size_t annotations=builder.texts.size()+builder.dimensions.size()+builder.construction_lines.size()+builder.construction_points.size()+builder.section_planes.size();if(annotations)[unsupported addObject:@{@"id":nodeID,@"name":Text(name),@"type":@"Text/Dimension/Guide/SectionPlane",@"count":@(annotations)}];
                    for(const auto &inst:builder.instances){c.check();if(!inst.ref_idx)throw Failure(1,"SKP 组件缺少定义引用。");auto def=model.definitions.find(*inst.ref_idx);if(def==model.definitions.end())throw Failure(1,"SKP 组件引用的定义不存在。");if(!active.insert(*inst.ref_idx).second)throw Failure(1,"SKP 组件定义出现循环引用。");auto inherited=inst.material_id?openskp::find_material(model,inst.material_id):paint;auto childLayer=resolveLayer(inst.layer,effectiveLayer);std::string childName=inst.name.empty()?def->second.name:inst.name;if(childName.empty())childName="组件";self(self,def->second.builder,*inst.ref_idx,Multiply(world,Matrix(inst.matrix)),childName,childLayer,inherited,visible&&!inst.hidden,visibilityLayers,nodeID,depth+1);active.erase(*inst.ref_idx);}
                }
            };
            walk(walk,model.root.builder,{},Identity(),"模型","Layer0",nullptr,true,@[],nil,0);
            if(unsupported.count>0)[warnings addObject:@"部分文字、标注、辅助线或剖切设置尚未显示，可在对象信息中查看记录"];
            if(objects.count==0)throw Failure(1,"SKP 文件没有可显示的网格或线条。");
            manifest[@"complete"]=@YES;publish(@"complete");return YES;
        } catch(const Failure &f){operationError=[NSError errorWithDomain:@"O3DVSKP" code:f.code userInfo:@{NSLocalizedDescriptionKey:Text(f.what())}];}
          catch(const std::bad_alloc&){operationError=[NSError errorWithDomain:@"O3DVSKP" code:cancel.cancelled?3:2 userInfo:@{NSLocalizedDescriptionKey:cancel.cancelled?@"读取已取消。":@"SKP 解析超过当前设备的资源预算，已停止加载。"}];}
          catch(const std::exception&f){operationError=[NSError errorWithDomain:@"O3DVSKP" code:1 userInfo:@{NSLocalizedDescriptionKey:[@"SKP 数据无法完整解析：" stringByAppendingString:Text(f.what())]}];}
    }
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];if(error)*error=operationError;return NO;
}
@end
