#import <Foundation/Foundation.h>
#import "GltfStreamReader.h"
#include "DracoMemory.hpp"
#include "NativeMemory.hpp"
#include <cassert>
#include <filesystem>
@implementation RhinoReadCancellation
@end
int main(int argc,char **argv){@autoreleasepool {
    if(argc!=3)return 2;
    NSString *source=[NSString stringWithUTF8String:argv[1]],*root=[NSString stringWithUTF8String:argv[2]];
    size_t firstFootprint=0,firstDescriptors=0;
    for(int step=0;step<6;step++){
        @autoreleasepool {
            RhinoReadCancellation *cancel=[RhinoReadCancellation new];
            if(step==1)cancel.decoderBudgetBytes=512;
            NSError *error=nil;NSString *folder=[root stringByAppendingPathComponent:[NSString stringWithFormat:@"run-%d",step]];
            BOOL ok=[GltfStreamReader convertFile:source toDirectory:folder progress:^(NSDictionary *info){
                if(step==3 && [info[@"phase"] isEqual:@"decoding"] && [info[@"decoderAllocationBytes"] unsignedLongLongValue]>0)cancel.cancelled=YES;
            } cancellation:cancel error:&error];
            if(step==1)assert(!ok && error.code==2);else if(step==3)assert(!ok && error.code==3);else assert(ok);
            cancel.cancelled=YES; // Closing the old model must not poison the next decoder's allocator.
            assert(!o3dv::ActiveDracoBudget());
            assert([NSFileManager.defaultManager removeItemAtPath:folder error:nil]);
        }
        size_t descriptors=0;for(auto &entry:std::filesystem::directory_iterator("/dev/fd")){(void)entry;descriptors++;}
        auto memory=o3dv::SampleMemory();
        if(step==0){firstFootprint=memory.footprint;firstDescriptors=descriptors;}
        assert(memory.footprint<firstFootprint+64*1024*1024 && descriptors<=firstDescriptors+2);
        printf("step=%d footprint=%zu descriptors=%zu\n",step,memory.footprint,descriptors);fflush(stdout);
    }
    printf("PASS same-process success, resource rejection, decode cancellation and reopen; stable footprint/descriptors\n");
}return 0;}
