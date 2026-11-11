#import <Foundation/Foundation.h>
#import "GltfStreamReader.h"
#include "NativeMemory.hpp"
@implementation RhinoReadCancellation
@end
int main(int argc,char **argv){@autoreleasepool {
    if(argc!=3){fprintf(stderr,"usage: gltf-stream input.glb/input.gltf cache-directory\n");return 2;}
    RhinoReadCancellation *cancel=[RhinoReadCancellation new];if(getenv("O3DV_TEST_CANCEL"))cancel.cancelled=YES;
    if(const char *budget=getenv("O3DV_TEST_DECODER_BUDGET"))cancel.decoderBudgetBytes=strtoull(budget,nullptr,10);
    if(getenv("O3DV_TEST_CRITICAL_PRESSURE"))o3dv::MemoryPressure().store(2);
    NSError *error=nil;
    BOOL ok=[GltfStreamReader convertFile:[NSString stringWithUTF8String:argv[1]] toDirectory:[NSString stringWithUTF8String:argv[2]] progress:^(NSDictionary *state){
        printf("%s\n",[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
        if(getenv("O3DV_TEST_CANCEL_AFTER_READY")&&[state[@"phase"] isEqual:@"ready"])cancel.cancelled=YES;
        if(getenv("O3DV_TEST_CANCEL_DURING_DECODE")&&[state[@"phase"] isEqual:@"decoding"]&&[state[@"decoderAllocationBytes"] unsignedLongLongValue]>0)cancel.cancelled=YES;
    } cancellation:cancel error:&error];
    if(!ok){fprintf(stderr,"%s:%ld %s\n",error.domain.UTF8String,(long)error.code,error.localizedDescription.UTF8String);return 1;}
}return 0;}
