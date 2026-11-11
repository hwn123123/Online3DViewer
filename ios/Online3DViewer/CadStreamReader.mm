#import "CadStreamReader.h"
#include "NativeMemory.hpp"
#include "NativeReadLock.hpp"
#include <sys/statvfs.h>
#include <chrono>
#include <algorithm>
#include "CadTextRenderer.h"
extern "C" {
int o3dv_cad_convert(const char *,const char *,int (*)(void *,size_t),void (*)(void *,const unsigned char *,size_t),void (*)(void *,uint64_t *),int (*)(void *,const unsigned char *,size_t,void *,O3DVCadTextEmit),void *,size_t,char **);
void o3dv_cad_free(char *);
}
namespace {
using Clock=std::chrono::steady_clock;
struct Context {
    __strong NSString *directory;
    __strong RhinoReadCancellation *cancel;
    __strong void (^progress)(NSDictionary *);
    __strong NSString *failure=nil;
    uint64_t peakFootprint=0,peakResident=0,largestRequest=0,objects=0;
    bool decoding=true;
    int code=0;Clock::time_point lastCheck={},lastReport={},lastStorage={};
    int check(size_t requested){
        if(code)return code;
        if(cancel.cancelled){failure=@"读取已取消。";return code=3;}
        largestRequest=std::max(largestRequest,uint64_t(requested));
        size_t limit=cancel.decoderBudgetBytes?cancel.decoderBudgetBytes:128*o3dv::MemoryMiB;
        if(requested>limit){failure=@"CAD 解析需要的单次内存超过当前预算，已停止任务。";return code=2;}
        auto now=Clock::now();bool allocation=requested>=o3dv::MemoryMiB;
        if(!allocation&&now-lastCheck<std::chrono::milliseconds(5)&&o3dv::MemoryPressure().load()<2)return 0;
        lastCheck=now;
        auto m=o3dv::SampleMemory();peakFootprint=std::max(peakFootprint,uint64_t(m.footprint));peakResident=std::max(peakResident,uint64_t(m.resident));
        if(requested>limit || m.pressure>=2 || m.footprint>448*o3dv::MemoryMiB ||
           requested>512*o3dv::MemoryMiB-std::min(m.footprint+64*o3dv::MemoryMiB,512*o3dv::MemoryMiB) ||
           (m.availableKnown && (m.available<64*o3dv::MemoryMiB || requested>m.available-32*o3dv::MemoryMiB))){
            failure=@"设备当前可用内存不足以继续完整读取 CAD 图纸，已停止任务。";return code=2;
        }
        if(now-lastStorage>std::chrono::milliseconds(200)){
            lastStorage=now;struct statvfs fs={};
            if(statvfs(directory.fileSystemRepresentation,&fs)!=0||uint64_t(fs.f_bavail)*fs.f_frsize<512*o3dv::MemoryMiB){
                failure=@"本地存储空间不足，无法保存完整 CAD 显示缓存。";return code=2;
            }
        }
        if(now-lastReport>std::chrono::milliseconds(150)){
            lastReport=now;progress(@{@"phase":decoding?@"decoding":@"building",@"objects":@(objects),@"decoderAllocationBytes":@(largestRequest)});
        }
        return 0;
    }
};
int Check(void *p,size_t size){@autoreleasepool{return static_cast<Context *>(p)->check(size);}}
void Event(void *p,const unsigned char *bytes,size_t length){@autoreleasepool{
    auto &c=*static_cast<Context *>(p);if(c.code)return;
    NSData *data=[NSData dataWithBytes:bytes length:length];
    NSDictionary *state=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if([state isKindOfClass:NSDictionary.class]){
        c.objects=[state[@"objects"]unsignedLongLongValue];
        if(![state[@"phase"]isEqual:@"decoding"])c.decoding=false;
        c.progress(state);
    }
}}
void Snapshot(void *p,uint64_t *output){auto &c=*static_cast<Context *>(p);auto m=o3dv::SampleMemory();c.peakFootprint=std::max(c.peakFootprint,uint64_t(m.footprint));c.peakResident=std::max(c.peakResident,uint64_t(m.resident));output[0]=c.peakFootprint;output[1]=c.peakResident;}
int Layout(void *p,const unsigned char *bytes,size_t length,void *sink,O3DVCadTextEmit emit){return O3DVCadLayoutText(bytes,length,sink,emit,p,Check);}
}
@implementation CadStreamReader
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory progress:(void (^)(NSDictionary<NSString *,id> *))progress cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error {
    std::unique_lock<std::mutex> lock(o3dv::NativeReadMutex());
    NSError *operationError=nil;
    if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&operationError]){if(error)*error=operationError;return NO;}
    Context context{directory,cancellation,progress};char *message=nullptr;
    O3DVCadClearTextCache();
    int result=o3dv_cad_convert(source.fileSystemRepresentation,directory.fileSystemRepresentation,Check,Event,Snapshot,Layout,&context,128*o3dv::MemoryMiB,&message);
    O3DVCadClearTextCache();
    NSString *detail=message?[NSString stringWithUTF8String:message]:@"CAD 读取未完成。";o3dv_cad_free(message);
    if(result==2 && !context.failure)context.failure=@"CAD 对象数据超过当前读取资源预算，已停止任务。";
    if(result || context.code || cancellation.cancelled){
        [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
        NSInteger code=context.code?:result;
        if(error)*error=[NSError errorWithDomain:@"O3DVCAD" code:code userInfo:@{NSLocalizedDescriptionKey:context.failure?:detail,
            @"resourceDiagnostics":@{@"nativePeakFootprintBytes":@(context.peakFootprint),@"nativePeakMemoryBytes":@(context.peakResident),@"largestDecoderRequestBytes":@(context.largestRequest)}}];
        return NO;
    }
    return YES;
}
@end
