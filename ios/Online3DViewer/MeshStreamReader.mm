#import "MeshStreamReader.h"
#include "ThirdParty/ufbx/ufbx.h"
#include "TrimmedSurface.hpp"
#include "NativeReadLock.hpp"
#include "MappedWorkspace.hpp"
#include "FbxMeshPages.hpp"
#import <CommonCrypto/CommonDigest.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <TargetConditionals.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t MiB = 1024 * 1024;
NSString *Text(ufbx_string s) {
    return [[NSString alloc] initWithBytes:s.data length:s.length encoding:NSUTF8StringEncoding] ?: @"";
}
uint64_t Resident() {
    mach_task_basic_info_data_t info = {}; mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    return task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.resident_size : 0;
}
struct Box {
    double min[3] = {INFINITY, INFINITY, INFINITY}, max[3] = {-INFINITY, -INFINITY, -INFINITY};
    void add(ufbx_vec3 p) { for (int k=0;k<3;k++) { min[k]=std::min(min[k],double(p.v[k])); max[k]=std::max(max[k],double(p.v[k])); } }
    NSArray *json() const { return std::isfinite(min[0]) ? @[@(min[0]),@(min[1]),@(min[2]),@(max[0]),@(max[1]),@(max[2])] : @[@0,@0,@0,@0,@0,@0]; }
};
struct Context {
    __strong RhinoReadCancellation *cancel;
    __strong void (^progress)(NSDictionary *);
    __strong NSString *root;
    __strong NSMutableArray *missing;
    std::unique_ptr<o3dv::MappedWorkspace> workspace;
    uint64_t residentPeak = 0;
    Clock::time_point last = Clock::now();
};
// Both parser allocators share a disk-backed workspace and a physical-footprint guard.
void *Realloc(void *user, void *ptr, size_t oldSize, size_t size) {
    auto &c = *(Context *)user;
    void *result=c.workspace->reallocate(ptr,oldSize,size);
    return result;
}
ufbx_progress_result Progress(void *user, const ufbx_progress *p) {
    auto &c = *(Context *)user;
    if (c.cancel.cancelled || !c.workspace->checkpoint()) return UFBX_PROGRESS_CANCEL;
    if (Clock::now()-c.last >= std::chrono::milliseconds(150)) {
        @autoreleasepool {
            c.residentPeak=std::max(c.residentPeak,Resident());
            c.progress(@{@"phase":@"parsing",@"objects":@0,@"bytesRead":@(p->bytes_read),@"sourceBytes":@(p->bytes_total)});
        }
        c.last=Clock::now();
    }
    return UFBX_PROGRESS_CONTINUE;
}
NSString *LocalPath(Context &c, NSString *reference) {
    reference=[reference stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    for (NSString *relative in @[reference,reference.lastPathComponent]) {
        NSString *path=[([relative hasPrefix:[c.root stringByAppendingString:@"/"]]?relative:[c.root stringByAppendingPathComponent:relative]) stringByResolvingSymlinksInPath];
        if ([path hasPrefix:[c.root stringByAppendingString:@"/"]] && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}
bool OpenExternal(void *user, ufbx_stream *stream, const char *path, size_t length, const ufbx_open_file_info *info) {
    auto &c=*(Context *)user;
    @autoreleasepool {
        NSString *requested=[[NSString alloc] initWithBytes:path length:length encoding:NSUTF8StringEncoding] ?: @"";
        NSString *local=LocalPath(c,requested);
        if (local) return ufbx_open_file_ctx(stream,info->context,local.fileSystemRepresentation,strlen(local.fileSystemRepresentation),nullptr,nullptr);
        if (![c.missing containsObject:requested.lastPathComponent]) [c.missing addObject:requested.lastPathComponent];
        return false;
    }
}
struct Key {
    float data[11]={};
    bool operator==(const Key &b) const { return memcmp(data,b.data,sizeof(data))==0; }
};
struct Hash {
    size_t operator()(const Key &k) const { size_t h=2166136261;for(float value:k.data) { uint32_t v;memcpy(&v,&value,4);h=(h*16777619)^v; }return h; }
};
struct Buffer {
    std::vector<float> positions,normals,uvs,colors,lines;
    std::vector<uint32_t> indices;
    std::unordered_map<Key,uint32_t,Hash> lookup;
    ufbx_vec3 origin={}; bool hasUV=false,hasColors=false,hasOrigin=false;
    Box box;
    ufbx_vec3 relative(ufbx_vec3 p) {
        box.add(p);
        if (!hasOrigin) { origin=p; hasOrigin=true; }
        return {p.x-origin.x,p.y-origin.y,p.z-origin.z};
    }
    void line(ufbx_vec3 a,ufbx_vec3 b) {
        a=relative(a); b=relative(b);
        for (auto p:{a,b}) lines.insert(lines.end(),{float(p.x),float(p.y),float(p.z)});
    }
    void vertex(const ufbx_mesh *m,const ufbx_node *node,uint32_t corner,const ufbx_matrix &normalMatrix) {
        const auto &pos=m->skinned_position.exists ? m->skinned_position : m->vertex_position;
        const auto &nor=m->skinned_normal.exists ? m->skinned_normal : m->vertex_normal;
        ufbx_vec3 p=ufbx_get_vertex_vec3(&pos,corner);
        if (m->skinned_is_local) p=ufbx_transform_position(&node->geometry_to_world,p);
        ufbx_vec3 n=nor.exists?ufbx_get_vertex_vec3(&nor,corner):ufbx_vec3{0,0,1};
        if(m->skinned_is_local) n=ufbx_transform_direction(&normalMatrix,n);
        n=ufbx_vec3_normalize(n);
        auto uv=hasUV?ufbx_get_vertex_vec2(&m->vertex_uv,corner):ufbx_vec2{};
        auto color=hasColors?ufbx_get_vertex_vec4(&m->vertex_color,corner):ufbx_vec4{};
        rawVertex(p,n,uv,color);
    }
    void rawVertex(ufbx_vec3 p,ufbx_vec3 n,ufbx_vec2 uv={},ufbx_vec4 color={}) {
        p=relative(p);
        Key key={{float(p.x),float(p.y),float(p.z),float(n.x),float(n.y),float(n.z),float(uv.x),float(uv.y),float(color.x),float(color.y),float(color.z)}};
        for(float &v:key.data) if(v==0) v=0; // Canonicalize -0 for exact binary equality.
        auto found=lookup.find(key);
        if(found!=lookup.end()) { indices.push_back(found->second);return; }
        uint32_t index=uint32_t(positions.size()/3);lookup.emplace(key,index);indices.push_back(index);
        positions.insert(positions.end(),key.data,key.data+3);normals.insert(normals.end(),key.data+3,key.data+6);
        if(hasUV) uvs.insert(uvs.end(),key.data+6,key.data+8);
        if(hasColors) colors.insert(colors.end(),key.data+8,key.data+11);
    }
    uint64_t write(NSString *path) {
        std::unique_ptr<FILE,decltype(&fclose)> file(fopen(path.fileSystemRepresentation,"wb"),&fclose);
        if(!file) throw std::runtime_error("无法写入几何缓存。");
        uint32_t header[8]={0x3144334f,2,uint32_t(positions.size()/3),uint32_t(indices.size()),uint32_t(lines.size()/3),uint32_t(hasColors),uint32_t(hasUV),0};
        uint64_t bytes=sizeof(header);
        if(fwrite(header,1,sizeof(header),file.get())!=sizeof(header)) throw std::runtime_error("几何缓存写入失败。");
        auto append=[&](const auto &v) {
            size_t size=v.size()*sizeof(typename std::decay_t<decltype(v)>::value_type);
            if(size && fwrite(v.data(),1,size,file.get())!=size) throw std::runtime_error("几何缓存写入失败。");
            bytes+=size;
        };
        append(positions);append(normals);append(indices);append(lines);append(colors);append(uvs);
        return bytes;
    }
};
}

namespace {
NSString *StableElementID(const ufbx_element *element) {
    if(element->dom_node && element->dom_node->values.count) {
        const auto &value=element->dom_node->values.data[0];
        if(value.type==UFBX_DOM_VALUE_NUMBER) return [NSString stringWithFormat:@"%lld",(long long)value.value_int];
        if(value.type==UFBX_DOM_VALUE_STRING) return Text(value.value_str);
    }
    return [NSString stringWithFormat:@"%u",element->element_id];
}
NSString *TextureDigest(NSString *path) {
    std::unique_ptr<FILE,decltype(&fclose)> file(fopen(path.fileSystemRepresentation,"rb"),&fclose);
    if(!file)throw std::runtime_error("无法读取材质缓存。");
    CC_SHA256_CTX state;CC_SHA256_Init(&state);std::vector<uint8_t> bytes(MiB);
    for(;;){size_t count=fread(bytes.data(),1,bytes.size(),file.get());if(count)CC_SHA256_Update(&state,bytes.data(),CC_LONG(count));if(count<bytes.size()){if(ferror(file.get()))throw std::runtime_error("材质缓存读取失败。");break;}}
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&state);
    char hex[CC_SHA256_DIGEST_LENGTH*2+1];for(size_t i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return [NSString stringWithUTF8String:hex];
}
}
@interface MeshStreamReader ()
+ (BOOL)convertSingleFile:(NSString *)source toDirectory:(NSString *)directory originalRoot:(NSString *)originalRoot stableIDs:(BOOL)stableIDs progress:(void (^)(NSDictionary<NSString *, id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error;
@end

@implementation MeshStreamReader
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory progress:(void (^)(NSDictionary<NSString *, id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    NSError *operationError=nil;
    auto convert=[&]() -> BOOL {
    auto fail=[&](NSString *message) {operationError=[NSError errorWithDomain:@"O3DVMesh" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;};
    NSFileManager *fm=[NSFileManager defaultManager];
    NSString *root=[source.stringByDeletingLastPathComponent stringByResolvingSymlinksInPath];
    uint64_t sourceBytes=[fm attributesOfItemAtPath:source error:nil].fileSize;
    uint64_t pageBudget=64*MiB;bool considerPages=sourceBytes>=16*MiB;
#if DEBUG || !TARGET_OS_IPHONE
    if(const char *value=getenv("O3DV_TEST_FBX_PAGE_BYTES")){pageBudget=std::max<uint64_t>(1,strtoull(value,nullptr,10));considerPages=true;}
    if(getenv("O3DV_TEST_FBX_WHOLE"))considerPages=false;
#endif
    if(!considerPages || ![source.pathExtension.lowercaseString isEqual:@"fbx"])
        return [self convertSingleFile:source toDirectory:directory originalRoot:root stableIDs:NO progress:progress cancellation:cancellation error:&operationError];
    NSString *work=[directory stringByAppendingPathComponent:@".fbx-pages"];
    @try { try {
        o3dv::FbxMeshPages container(source.fileSystemRepresentation,[cancellation]{return bool(cancellation.cancelled);});
        auto pages=container.pages(pageBudget);
        if(!container.supported || pages.size()<2)
            return [self convertSingleFile:source toDirectory:directory originalRoot:root stableIDs:NO progress:progress cancellation:cancellation error:&operationError];
        if(![fm createDirectoryAtPath:work withIntermediateDirectories:YES attributes:nil error:&operationError])return NO;
        NSMutableArray *objects=[NSMutableArray array],*materials=[NSMutableArray array],*unsupported=[NSMutableArray array],*missing=[NSMutableArray array];
        NSMutableDictionary<NSData *,NSNumber *> *materialKeys=[NSMutableDictionary dictionary];
        NSMutableDictionary *manifest=[@{@"format":@"o3dv-stream-1",@"reader":@"ufbx-pages-1",@"name":source.lastPathComponent,@"sourceBytes":@(sourceBytes),
            @"layers":@[@{@"id":@"model",@"index":@0,@"name":@"模型",@"visible":@YES}],@"objects":objects,@"materials":materials,@"unsupported":unsupported,@"missingFiles":missing,
            @"complete":@NO,@"parserPageCount":@(pages.size()),@"parserPageDecodedBudgetBytes":@(pageBudget)} mutableCopy];
        Box bounds;uint64_t sourceObjects=0;
        auto publish=[&](NSString *phase,size_t completed) {
            manifest[@"objectCount"]=@(objects.count);manifest[@"sourceObjectCount"]=@(sourceObjects);manifest[@"bounds"]=bounds.json();manifest[@"parserCompletedPages"]=@(completed);
            NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:&operationError];
            if(!data || ![data writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&operationError])throw std::runtime_error("无法写入分批模型清单。");
            progress(@{@"phase":phase,@"objects":@(sourceObjects),@"bytesRead":@(sourceBytes*completed/pages.size()),@"sourceBytes":@(sourceBytes)});
        };
        for(size_t page=0;page<pages.size();page++) {
            @autoreleasepool {
                if(cancellation.cancelled)return fail(@"读取已取消。");
                NSString *input=[work stringByAppendingPathComponent:@"page.fbx"],*output=[work stringByAppendingPathComponent:@"cache"];
                container.writePage(pages[page],input.fileSystemRepresentation);
                BOOL ok=[self convertSingleFile:input toDirectory:output originalRoot:root stableIDs:YES progress:^(NSDictionary *state) {
                    if([state[@"phase"] isEqual:@"parsing"]) {
                        double fraction=[state[@"sourceBytes"] doubleValue]>0?[state[@"bytesRead"] doubleValue]/[state[@"sourceBytes"] doubleValue]:0;
                        progress(@{@"phase":@"parsing",@"objects":@(sourceObjects),@"bytesRead":@(uint64_t(sourceBytes*(page+fraction)/pages.size())),@"sourceBytes":@(sourceBytes)});
                    }
                } cancellation:cancellation error:&operationError];
                if(!ok)return NO;
                NSDictionary *part=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[output stringByAppendingPathComponent:@"manifest.json"]] options:0 error:&operationError];
                if(!part || ![part[@"complete"] boolValue])throw std::runtime_error("分批解析结果不完整。");
                NSMutableDictionary *materialMap=[NSMutableDictionary dictionary],*textureNames=[NSMutableDictionary dictionary];
                for(NSDictionary *material in part[@"materials"]) {
                    NSMutableDictionary *value=[material mutableCopy];[value removeObjectForKey:@"index"];
                    for(NSString *key in @[@"texture",@"normalTexture",@"bumpTexture"])if([value[key] isKindOfClass:NSDictionary.class]) {
                        NSMutableDictionary *texture=[value[key] mutableCopy];NSString *name=texture[@"url"],*newName=textureNames[name];
                        if(!newName){NSString *file=[output stringByAppendingPathComponent:name];newName=[NSString stringWithFormat:@"texture-%@.%@",TextureDigest(file),name.pathExtension];
                            NSString *destination=[directory stringByAppendingPathComponent:newName];
                            if(![fm fileExistsAtPath:destination] && ![fm moveItemAtPath:file toPath:destination error:&operationError])return NO;
                            textureNames[name]=newName;}
                        texture[@"url"]=newName;value[key]=texture;
                    }
                    NSData *key=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&operationError];if(!key)throw std::runtime_error("材质清单不正确。");
                    NSNumber *index=materialKeys[key];if(!index){index=@(materials.count);materialKeys[key]=index;value[@"index"]=index;[materials addObject:value];}
                    materialMap[material[@"index"]]=index;
                }
                for(NSDictionary *item in part[@"objects"]) {
                    NSMutableDictionary *value=[item mutableCopy];NSString *name=[NSString stringWithFormat:@"object-%06lu.bin",(unsigned long)objects.count];
                    if(![fm moveItemAtPath:[output stringByAppendingPathComponent:item[@"url"]] toPath:[directory stringByAppendingPathComponent:name] error:&operationError])return NO;
                    value[@"url"]=name;value[@"id"]=[NSString stringWithFormat:@"chunk-%lu",(unsigned long)objects.count];value[@"index"]=@(objects.count);value[@"name"]=[NSString stringWithFormat:@"模型块 %lu",(unsigned long)objects.count+1];
                    value[@"materialIndex"]=materialMap[item[@"materialIndex"]]?:@(-1);[objects addObject:value];
                }
                for(NSDictionary *item in part[@"unsupported"])if(![unsupported containsObject:item])[unsupported addObject:item];
                for(NSString *name in part[@"missingFiles"])if(![missing containsObject:name])[missing addObject:name];
                sourceObjects+=[part[@"sourceObjectCount"] unsignedLongLongValue];
                NSArray *box=part[@"bounds"];if(box.count==6 && [part[@"objectCount"] unsignedLongLongValue]){bounds.add({[box[0] doubleValue],[box[1] doubleValue],[box[2] doubleValue]});bounds.add({[box[3] doubleValue],[box[4] doubleValue],[box[5] doubleValue]});}
                for(NSString *key in @[@"geometryBytes",@"vertices",@"triangles",@"lineSegments",@"sourceTriangles",@"trimmedSurfaceCount",@"displayedTrimmedSurfaceCount"])
                    manifest[key]=@([manifest[key] unsignedLongLongValue]+[part[key] unsignedLongLongValue]);
                for(NSString *key in @[@"nativePeakMemoryBytes",@"nativePeakFootprintBytes",@"parserLogicalPeakBytes",@"parserWorkspaceDiskBytes"])
                    manifest[key]=@(std::max([manifest[key] unsignedLongLongValue],[part[key] unsignedLongLongValue]));
                if(![fm removeItemAtPath:input error:&operationError] || ![fm removeItemAtPath:output error:&operationError])return NO;
                if(page+1==pages.size())manifest[@"complete"]=@YES;
                publish(page==0?@"ready":(page+1==pages.size()?@"complete":@"progress"),page+1);
            }
        }
        if(objects.count==0)return fail(@"此文件未解析出可显示的网格或曲线。");
        return YES;
    } catch(const std::bad_alloc &){return fail(@"分批解析所需资源不足，已停止加载。");}
      catch(const std::exception &e){return fail([NSString stringWithUTF8String:e.what()]);}
    } @finally { [fm removeItemAtPath:work error:nil]; }

    };
    BOOL success=convert();
    if(!success && error)*error=operationError;
    return success;
}

+ (BOOL)convertSingleFile:(NSString *)source toDirectory:(NSString *)directory originalRoot:(NSString *)originalRoot stableIDs:(BOOL)stableIDs progress:(void (^)(NSDictionary<NSString *, id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    auto fail=[&](NSString *message) { if(error) *error=[NSError errorWithDomain:@"O3DVMesh" code:1 userInfo:@{NSLocalizedDescriptionKey:message}]; return NO; };
    try {
            std::unique_lock<std::mutex> readLock(o3dv::NativeReadMutex());
            if(cancellation.cancelled) return fail(@"读取已取消。");
            if(![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
            Context context; context.cancel=cancellation;context.progress=progress;
            context.root=originalRoot;context.missing=[NSMutableArray array];
            context.workspace=std::make_unique<o3dv::MappedWorkspace>(directory.fileSystemRepresentation,[cancellation]{return bool(cancellation.cancelled);});
            auto resourceFail=[&](NSString *message) {
                auto &w=*context.workspace;
                if(error)*error=[NSError errorWithDomain:@"O3DVMesh" code:2 userInfo:@{NSLocalizedDescriptionKey:message,
                    @"resourceDiagnostics":@{@"freeStorageBefore":@(w.freeAtStart),@"freeStorageLast":@(w.lastFree),
                    @"workspaceBytes":@(w.diskBytes),@"parserLogicalPeakBytes":@(w.peakAllocated),
                    @"nativePeakFootprintBytes":@(w.peakFootprint),@"systemError":@(w.systemError)}}];
                return NO;
            };
            ufbx_load_opts opts={}; opts.ignore_animation=true;opts.retain_dom=stableIDs;opts.generate_missing_normals=true;opts.evaluate_skinning=true;
            opts.target_axes=ufbx_axes_right_handed_z_up;opts.node_depth_limit=512;
            opts.obj_axes=ufbx_axes_right_handed_y_up;
            opts.load_external_files=true;opts.ignore_missing_external_files=true;opts.open_main_file_with_default=true;
            opts.open_file_cb.fn=OpenExternal;opts.open_file_cb.user=&context;
            opts.progress_cb.fn=Progress;opts.progress_cb.user=&context;opts.progress_interval_hint=MiB;
            opts.temp_allocator.allocator.realloc_fn=Realloc;opts.temp_allocator.allocator.user=&context;
            opts.result_allocator.allocator=opts.temp_allocator.allocator;
            ufbx_error loadError={};
            std::unique_ptr<ufbx_scene,decltype(&ufbx_free_scene)> scene(ufbx_load_file(source.fileSystemRepresentation,&opts,&loadError),&ufbx_free_scene);
            if(!scene) {
                if(cancellation.cancelled) return fail(@"读取已取消。");
                using Failure=o3dv::MappedWorkspace::Failure;
                auto reason=context.workspace->failure;
                if(reason==Failure::disk)return resourceFail(@"本地工作区存储分配失败，已停止处理模型。可在存储管理中检查可用空间。");
                if(reason==Failure::addressSpace)return resourceFail(@"设备当前无法为解析工作区提供足够的地址空间，已停止加载。");
                if(reason==Failure::pressure)return resourceFail(@"设备内存压力过高，已停止加载并释放解析工作区。");
                if(reason==Failure::io)return resourceFail(@"本地解析工作区读写失败，已停止加载。");
                if(loadError.type==UFBX_ERROR_OUT_OF_MEMORY || loadError.type==UFBX_ERROR_MEMORY_LIMIT) return fail(@"此模型解析超出当前设备的内存预算，已停止加载。");
                return fail([@"模型解析失败：" stringByAppendingString:Text(loadError.description)]);
            }
            if(!context.workspace->checkpoint(true)) return fail(@"设备当前资源不足，已停止解析。");
            NSMutableArray *objects=[NSMutableArray array],*unsupported=[NSMutableArray array],*materials=[NSMutableArray array];
            uint64_t bytes=0,vertices=0,triangles=0,lineSegments=0,sourceObjects=0,sourceTriangles=0,trimCount=0,displayedTrims=0;
            Box bounds;
            // Cache textures locally; never resolve a referenced path outside the imported folder.
            NSMutableDictionary *textureCache=[NSMutableDictionary dictionary];
            auto texture=[&](ufbx_texture *t)->id {
                if(!t) return [NSNull null];
                if(t->type!=UFBX_TEXTURE_FILE) t=t->file_textures.count?t->file_textures.data[0]:nullptr;
                if(!t) return [NSNull null];
                NSString *key=[NSString stringWithFormat:@"%u",t->element_id];
                if(textureCache[key]) return textureCache[key];
                NSString *reference=Text(t->relative_filename); if(!reference.length) reference=Text(t->filename);
                NSString *name=[NSString stringWithFormat:@"texture-%u.%@",t->element_id,reference.pathExtension.length?reference.pathExtension:@"png"];
                NSString *destination=[directory stringByAppendingPathComponent:name];
                BOOL saved=NO;
                if(t->content.size) saved=[[NSData dataWithBytesNoCopy:(void *)t->content.data length:t->content.size freeWhenDone:NO] writeToFile:destination options:NSDataWritingAtomic error:nil];
                else if(NSString *local=LocalPath(context,reference)) saved=[[NSFileManager defaultManager] copyItemAtPath:local toPath:destination error:nil];
                if(!saved) { if(reference.length && ![context.missing containsObject:reference]) [context.missing addObject:reference];textureCache[key]=[NSNull null];return [NSNull null]; }
                auto &m=t->uv_to_texture;
                NSDictionary *value=@{@"url":name,@"matrix":@[@(m.m00),@(m.m10),@0,@(m.m01),@(m.m11),@0,@(m.m03),@(m.m13),@1],
                    @"wrapU":@(t->wrap_u==UFBX_WRAP_REPEAT),@"wrapV":@(t->wrap_v==UFBX_WRAP_REPEAT)};
                textureCache[key]=value;return value;
            };
            for(ufbx_material *m:scene->materials) {
                @autoreleasepool {
                    auto col=m->pbr.base_color.has_value?m->pbr.base_color.value_vec3:
                        (m->fbx.diffuse_color.has_value?m->fbx.diffuse_color.value_vec3:ufbx_vec3{0.7,0.72,0.75});
                    double opacity=m->pbr.opacity.has_value?m->pbr.opacity.value_real:1.0-m->fbx.transparency_factor.value_real;
                    ufbx_texture *map=m->pbr.base_color.texture_enabled?m->pbr.base_color.texture:m->fbx.diffuse_color.texture;
                    [materials addObject:@{@"index":@(m->typed_id),@"name":Text(m->name),@"color":@[@(col.x),@(col.y),@(col.z)],
                        @"opacity":@(std::clamp(opacity,0.0,1.0)),@"texture":texture(map),@"normalTexture":texture(m->fbx.normal_map.texture),
                        @"bumpTexture":texture(m->fbx.bump.texture),@"shininess":@(m->fbx.specular_exponent.value_real)}];
                }
            }
            NSArray *layers=@[@{@"id":@"model",@"index":@0,@"name":@"模型",@"visible":@YES}];
            auto sourceBytes=[[[NSFileManager defaultManager] attributesOfItemAtPath:source error:nil][NSFileSize] unsignedLongLongValue];
            NSMutableDictionary *manifest=[@{@"format":@"o3dv-stream-1",@"reader":@"ufbx-memory-1",@"name":source.lastPathComponent,
                @"sourceBytes":@(sourceBytes),@"layers":layers,@"materials":materials,@"objects":objects,@"unsupported":unsupported,
                @"missingFiles":context.missing,@"complete":@NO} mutableCopy];
            auto lastPublish=Clock::now();
            auto publish=[&](NSString *phase) {
                @autoreleasepool {
                    context.residentPeak=std::max(context.residentPeak,Resident());
                    [manifest addEntriesFromDictionary:@{@"objectCount":@(objects.count),@"sourceObjectCount":@(sourceObjects),
                        @"geometryBytes":@(bytes),@"vertices":@(vertices),@"triangles":@(triangles),@"lineSegments":@(lineSegments),
                        @"sourceTriangles":@(sourceTriangles),@"nativePeakMemoryBytes":@(context.residentPeak),@"bounds":bounds.json()}];
                    manifest[@"trimmedSurfaceCount"]=@(trimCount);manifest[@"displayedTrimmedSurfaceCount"]=@(displayedTrims);
                    manifest[@"nativePeakFootprintBytes"]=@(context.workspace->peakFootprint);
                    manifest[@"parserLogicalPeakBytes"]=@(context.workspace->peakAllocated);
                    manifest[@"parserWorkspaceDiskBytes"]=@(context.workspace->diskBytes);
                    NSData *data=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:error];
                    if(!data || ![data writeToFile:[directory stringByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:error]) throw std::runtime_error("无法写入模型清单。");
                    progress(@{@"phase":phase,@"objects":@(sourceObjects),@"bytesRead":@(sourceBytes),@"sourceBytes":@(sourceBytes)});
                }
                lastPublish=Clock::now();
            };
            publish(@"ready");
            Buffer buffer;
            int currentMaterial=-2;
            bool currentVisible=true;
            NSMutableArray *parts=[NSMutableArray array];
            auto flush=[&]() {
                if(buffer.indices.empty() && buffer.lines.empty()) return;
                if(!context.workspace->checkpoint()) throw std::runtime_error("设备当前资源不足，已停止模型处理。");
                NSString *file=[NSString stringWithFormat:@"object-%06lu.bin",(unsigned long)objects.count];
                uint64_t size=buffer.write([directory stringByAppendingPathComponent:file]);
                NSDictionary *mat=currentMaterial>=0 && currentMaterial<int(materials.count)?materials[currentMaterial]:nil;
                [objects addObject:@{@"id":[NSString stringWithFormat:@"chunk-%lu",(unsigned long)objects.count],
                    @"index":@(objects.count),@"name":[NSString stringWithFormat:@"模型块 %lu",(unsigned long)objects.count+1],
                    @"type":@"Geometry",@"parts":parts,@"layerIndex":@0,@"materialIndex":@(currentMaterial),
                    @"color":mat[@"color"]?:@[@0.7,@0.72,@0.75],@"opacity":mat[@"opacity"]?:@1,@"lineColor":@[@0.25,@0.25,@0.25],
                    @"visible":@(currentVisible),@"definitionMember":@NO,@"available":@YES,@"bounds":buffer.box.json(),
                    @"origin":@[@(buffer.origin.x),@(buffer.origin.y),@(buffer.origin.z)],@"url":file,@"bytes":@(size),
                    @"vertices":@(buffer.positions.size()/3),@"triangles":@(buffer.indices.size()/3),@"lineSegments":@(buffer.lines.size()/6)}];
                bounds.add({buffer.box.min[0],buffer.box.min[1],buffer.box.min[2]});bounds.add({buffer.box.max[0],buffer.box.max[1],buffer.box.max[2]});
                bytes+=size;vertices+=buffer.positions.size()/3;triangles+=buffer.indices.size()/3;lineSegments+=buffer.lines.size()/6;
                buffer=Buffer();parts=[NSMutableArray array];
                if(objects.count==1 || Clock::now()-lastPublish>std::chrono::milliseconds(250)) publish(@"progress");
            };
            for(ufbx_node *node:scene->nodes) {
                if(cancellation.cancelled) return fail(@"读取已取消。");
                for(ufbx_element *attribute:node->all_attribs) {
                    @autoreleasepool {
                        ufbx_mesh *mesh=ufbx_as_mesh(attribute);
                        ufbx_line_curve *curve=ufbx_as_line_curve(attribute);
                        ufbx_nurbs_curve *nurbs=ufbx_as_nurbs_curve(attribute);
                        ufbx_nurbs_surface *surface=ufbx_as_nurbs_surface(attribute);
                        bool trimmed=ufbx_as_nurbs_trim_surface(attribute)!=nullptr;
                        if(!mesh && !curve && !nurbs && !surface && !trimmed) {
                            if(attribute->type==UFBX_ELEMENT_PROCEDURAL_GEOMETRY || attribute->type==UFBX_ELEMENT_UNKNOWN)
                                [unsupported addObject:@{@"id":@(attribute->element_id),@"name":Text(node->name),@"type":@"UnsupportedGeometry"}];
                            continue;
                        }
                        sourceObjects++;
                        NSString *identifier=stableIDs?[NSString stringWithFormat:@"%@-%@",StableElementID(&node->element),StableElementID(attribute)]:[NSString stringWithFormat:@"%u-%u",node->element_id,attribute->element_id];
                        NSString *name=Text(node->name);
                        bool visible=true;for(ufbx_node *p=node;p;p=p->parent) visible &= p->visible;
                        bool emitted=false;
                        auto begin=[&](int material,bool uv,bool color) {
                            if(currentMaterial!=material || currentVisible!=visible || buffer.hasUV!=uv || buffer.hasColors!=color ||
                               buffer.indices.size()>=180000 || buffer.lines.size()>=180000) flush();
                            currentMaterial=material;currentVisible=visible;buffer.hasUV=uv;buffer.hasColors=color;
                            if(![parts.lastObject[@"id"] isEqual:identifier]) {
                                [parts addObject:[@{@"id":identifier,@"name":name,@"type":(mesh || surface || trimmed)?@"Mesh":@"Curve",
                                    @"start":@(buffer.indices.size()),@"lineStart":@(buffer.lines.size()/3)} mutableCopy]];
                            }
                            emitted=true;
                        };
                        std::unique_ptr<ufbx_mesh,decltype(&ufbx_free_mesh)> tessSurface(nullptr,&ufbx_free_mesh);
                        if(surface) {
                            ufbx_tessellate_surface_opts to={};
                            to.span_subdivision_u=surface->span_subdivision_u?:4;to.span_subdivision_v=surface->span_subdivision_v?:4;
                            to.temp_allocator=opts.temp_allocator;to.result_allocator=opts.result_allocator;
                            tessSurface.reset(ufbx_tessellate_nurbs_surface(surface,&to,nullptr));mesh=tessSurface.get();
                        }
                        if(trimmed) {
                            trimCount++;
                            o3dv::TrimPolygon polygon;
                            if(o3dv::ReadTrim(attribute,polygon,&opts.temp_allocator)) {
                                auto *s=polygon.surface;
                                Box localBounds;for(auto p:s->control_points) localBounds.add({p.x,p.y,p.z});
                                double tolerance=0;for(int k=0;k<3;k++) tolerance+=std::pow(localBounds.max[k]-localBounds.min[k],2);
                                tolerance=std::max(1e-7,std::sqrt(tolerance)*1e-4);
                                // A nonlinear parameterization of a plane needs no interior subdivision.
                                bool planar=true;ufbx_vec3 planeNormal={};
                                if(s->control_points.count>=3) {
                                    auto a=s->control_points.data[0];
                                    ufbx_vec3 edge={};
                                    for(auto p:s->control_points) {
                                        ufbx_vec3 d={p.x-a.x,p.y-a.y,p.z-a.z};
                                        if(edge.x==0 && edge.y==0 && edge.z==0) { if(std::hypot(std::hypot(d.x,d.y),d.z)>tolerance) edge=d;continue; }
                                        planeNormal={edge.y*d.z-edge.z*d.y,edge.z*d.x-edge.x*d.z,edge.x*d.y-edge.y*d.x};
                                        double length=std::hypot(std::hypot(planeNormal.x,planeNormal.y),planeNormal.z);
                                        if(length>tolerance*tolerance) {planeNormal=ufbx_vec3_normalize(planeNormal);break;}
                                    }
                                    for(auto p:s->control_points) if(std::abs((p.x-a.x)*planeNormal.x+(p.y-a.y)*planeNormal.y+(p.z-a.z)*planeNormal.z)>tolerance) planar=false;
                                }
                                auto normalMatrix=ufbx_matrix_for_normals(&node->geometry_to_world);
                                size_t emittedTriangles=0;
                                auto sample=[&](o3dv::UV uv) {
                                    auto p=ufbx_evaluate_nurbs_surface(s,uv[0],uv[1]);
                                    if(!p.valid) throw std::runtime_error("裁剪曲面包含无效参数，已停止以避免显示错误。");
                                    return p;
                                };
                                std::function<void(o3dv::UV,o3dv::UV,o3dv::UV,int)> emitTriangle;
                                emitTriangle=[&](o3dv::UV a,o3dv::UV b,o3dv::UV c,int depth) {
                                    if(cancellation.cancelled) throw std::runtime_error("读取已取消。");
                                    auto pa=sample(a),pb=sample(b),pc=sample(c);
                                    o3dv::UV ab={(a[0]+b[0])*.5,(a[1]+b[1])*.5},bc={(b[0]+c[0])*.5,(b[1]+c[1])*.5},ca={(c[0]+a[0])*.5,(c[1]+a[1])*.5};
                                    auto error=[&](o3dv::UV uv,ufbx_vec3 p,ufbx_vec3 q) {
                                        auto mid=sample(uv).position;
                                        ufbx_vec3 d={q.x-p.x,q.y-p.y,q.z-p.z};double length=d.x*d.x+d.y*d.y+d.z*d.z;
                                        double t=length?std::clamp(((mid.x-p.x)*d.x+(mid.y-p.y)*d.y+(mid.z-p.z)*d.z)/length,0.0,1.0):0;
                                        return std::sqrt(std::pow(mid.x-p.x-t*d.x,2)+std::pow(mid.y-p.y-t*d.y,2)+std::pow(mid.z-p.z-t*d.z,2));
                                    };
                                    if(!planar && depth<8 && std::max({error(ab,pa.position,pb.position),error(bc,pb.position,pc.position),error(ca,pc.position,pa.position)})>tolerance) {
                                        emitTriangle(a,ab,ca,depth+1);emitTriangle(ab,b,bc,depth+1);emitTriangle(ca,bc,c,depth+1);emitTriangle(ab,bc,ca,depth+1);return;
                                    }
                                    if(++emittedTriangles>1000000) throw std::runtime_error("单个裁剪曲面过于复杂，已停止加载。");
                                    begin(node->materials.count?int(node->materials.data[0]->typed_id):-1,false,false);
                                    for(auto point:{pa,pb,pc}) {
                                        auto a=point.derivative_u,b=point.derivative_v;
                                        ufbx_vec3 n={a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};
                                        if(s->flip_normals) { n.x=-n.x;n.y=-n.y;n.z=-n.z; }
                                        n=ufbx_vec3_normalize(ufbx_transform_direction(&normalMatrix,n));
                                        buffer.rawVertex(ufbx_transform_position(&node->geometry_to_world,point.position),n);
                                    }
                                    parts.lastObject[@"end"]=@(buffer.indices.size());parts.lastObject[@"lineEnd"]=@(buffer.lines.size()/3);
                                };
                                for(size_t i=0;i<polygon.indices.size();i+=3)
                                    emitTriangle(polygon.points[polygon.indices[i]],polygon.points[polygon.indices[i+1]],polygon.points[polygon.indices[i+2]],0);
                                displayedTrims++;
                            }
                        } else if(mesh) {
                            if(!surface) sourceTriangles+=mesh->num_triangles;
                            ufbx_matrix normalMatrix=ufbx_matrix_for_normals(&node->geometry_to_world);
                            bool mirrored=ufbx_matrix_determinant(&node->geometry_to_world)<0;
                            std::vector<uint32_t> faceIndices(mesh->max_face_triangles*3);
                            for(size_t f=0;f<mesh->faces.count;f++) {
                                if((f%4096)==0 && cancellation.cancelled) throw std::runtime_error("读取已取消。");
                                auto face=mesh->faces.data[f];int material=-1;
                                uint32_t slot=mesh->face_material.count?mesh->face_material.data[f]:0;
                                if(slot<node->materials.count) material=int(node->materials.data[slot]->typed_id);
                                if(face.num_indices<2) continue;
                                begin(material,mesh->vertex_uv.exists,mesh->vertex_color.exists);
                                if(face.num_indices==2) {
                                    auto a=ufbx_get_vertex_vec3(&mesh->vertex_position,face.index_begin),b=ufbx_get_vertex_vec3(&mesh->vertex_position,face.index_begin+1);
                                    buffer.line(ufbx_transform_position(&node->geometry_to_world,a),ufbx_transform_position(&node->geometry_to_world,b));
                                } else if(face.num_indices>=3) {
                                    uint32_t count=ufbx_triangulate_face(faceIndices.data(),faceIndices.size(),mesh,face);
                                    if(count!=face.num_indices-2) throw std::runtime_error("模型包含无法完整三角化的面，已停止以避免缺失几何。");
                                    for(uint32_t t=0;t<count;t++) for(int k=0;k<3;k++) buffer.vertex(mesh,node,faceIndices[t*3+(mirrored?2-k:k)],normalMatrix);
                                }
                                parts.lastObject[@"end"]=@(buffer.indices.size());parts.lastObject[@"lineEnd"]=@(buffer.lines.size()/3);
                            }
                        } else if(curve || nurbs) {
                            std::unique_ptr<ufbx_line_curve,decltype(&ufbx_free_line_curve)> tess(nullptr,&ufbx_free_line_curve);
                            if(nurbs) {
                                ufbx_tessellate_curve_opts to={};to.span_subdivision=16;
                                to.temp_allocator=opts.temp_allocator;to.result_allocator=opts.result_allocator;
                                tess.reset(ufbx_tessellate_nurbs_curve(nurbs,&to,nullptr));curve=tess.get();
                            }
                            if(curve) {
                                for(auto segment:curve->segments) for(uint32_t i=1;i<segment.num_indices;i++) {
                                    auto a=curve->control_points.data[curve->point_indices.data[segment.index_begin+i-1]];
                                    auto b=curve->control_points.data[curve->point_indices.data[segment.index_begin+i]];
                                    begin(-1,false,false);
                                    buffer.line(ufbx_transform_position(&node->geometry_to_world,a),ufbx_transform_position(&node->geometry_to_world,b));
                                    parts.lastObject[@"end"]=@(buffer.indices.size());parts.lastObject[@"lineEnd"]=@(buffer.lines.size()/3);
                                }
                            }
                        }
                        // An intentionally empty mesh is not missing geometry.
                        if(!emitted && (!mesh || mesh->num_triangles || mesh->num_line_faces || mesh->num_point_faces))
                            [unsupported addObject:@{@"id":identifier,@"name":name,@"type":trimmed?@"TrimNurbsSurface":(surface?@"NurbsSurface":@"UnsupportedGeometry")}];
                    }
                }
            }
            flush();
            // Release the full native scene before the final display/thumbnail work.
            context.residentPeak=std::max(context.residentPeak,Resident());scene.reset();
            if(objects.count==0 && !stableIDs) return fail(@"此文件未解析出可显示的网格或曲线。");
            manifest[@"complete"]=@YES;publish(@"complete");
            return YES;
    } catch(const std::bad_alloc &) { return fail(@"解析所需内存不足，已停止加载。"); }
      catch(const std::exception &e) { return fail([NSString stringWithUTF8String:e.what()]); }
}
@end
