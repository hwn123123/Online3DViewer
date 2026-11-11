#import <Foundation/Foundation.h>
#import "SkpStreamReader.h"
#include "SkpMemory.hpp"
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
            BOOL ok=[SkpStreamReader convertFile:source toDirectory:folder progress:^(NSDictionary *info){
                if(step==3 && [info[@"phase"] isEqual:@"decoding"] && [info[@"decoderAllocationBytes"] unsignedLongLongValue]>4*1024*1024)cancel.cancelled=YES;
            } cancellation:cancel error:&error];
            if(step==1)assert(!ok && error.code==2);else if(step==3)assert(!ok && error.code==3);else assert(ok);
            cancel.cancelled=YES;
            assert(!o3dv::ActiveSkpBudget());
            if(ok)assert([NSFileManager.defaultManager removeItemAtPath:folder error:nil]);
            else assert(![NSFileManager.defaultManager fileExistsAtPath:folder]);
        }
        size_t descriptors=0;for(auto &entry:std::filesystem::directory_iterator("/dev/fd")){(void)entry;descriptors++;}
        auto memory=o3dv::SampleMemory();
        if(step==0){firstFootprint=memory.footprint;firstDescriptors=descriptors;}
        assert(memory.footprint<firstFootprint+64*1024*1024 && descriptors<=firstDescriptors+2);
        printf("step=%d footprint=%zu descriptors=%zu\n",step,memory.footprint,descriptors);fflush(stdout);
    }
    printf("PASS same-process SKP success, resource rejection, decode cancellation and reopen\n");
}return 0;}
