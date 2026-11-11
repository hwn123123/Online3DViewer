#import <Foundation/Foundation.h>
#import "CadStreamReader.h"
#include "NativeMemory.hpp"
#include <chrono>
@implementation RhinoReadCancellation
@end
int main(int argc,char **argv){@autoreleasepool{
    if(argc!=3){fprintf(stderr,"usage: cad-stream input cache-directory\n");return 2;}
    auto cancel=[RhinoReadCancellation new];if(getenv("O3DV_TEST_CANCEL"))cancel.cancelled=YES;
    if(auto value=getenv("O3DV_TEST_DECODER_BUDGET"))cancel.decoderBudgetBytes=strtoull(value,nullptr,10);
    if(getenv("O3DV_TEST_CRITICAL_PRESSURE"))o3dv::MemoryPressure().store(2);
    NSError *error=nil;
    auto started=std::chrono::steady_clock::now();
    BOOL ok=[CadStreamReader convertFile:[NSString stringWithUTF8String:argv[1]] toDirectory:[NSString stringWithUTF8String:argv[2]] progress:^(NSDictionary *state){
        puts([[NSString alloc]initWithData:[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
        if(getenv("O3DV_TEST_CANCEL_AFTER_READY")&&[state[@"phase"]isEqual:@"ready"])cancel.cancelled=YES;
        if(auto t=getenv("O3DV_TEST_CANCEL_AFTER")){if(std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count()>atof(t))cancel.cancelled=YES;}
    } cancellation:cancel error:&error];
    if(!ok){fprintf(stderr,"%s:%ld %s\n",error.domain.UTF8String,(long)error.code,error.localizedDescription.UTF8String);return 1;}
}return 0;}
