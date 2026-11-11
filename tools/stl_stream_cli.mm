#import <Foundation/Foundation.h>
#import "StlStreamReader.h"
#include "NativeMemory.hpp"

// The standalone STL test target does not link the openNURBS reader.
@implementation RhinoReadCancellation
@end

int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=3) {fprintf(stderr,"usage: stl-stream input.stl cache-directory\n");return 2;}
        RhinoReadCancellation *cancel=[RhinoReadCancellation new];
        if(getenv("O3DV_TEST_CANCEL"))cancel.cancelled=YES;
        if(getenv("O3DV_TEST_CRITICAL_PRESSURE"))o3dv::MemoryPressure().store(2);
        NSError *error=nil;
        BOOL ok=[StlStreamReader convertFile:[NSString stringWithUTF8String:argv[1]] toDirectory:[NSString stringWithUTF8String:argv[2]]
            progress:^(NSDictionary *state) {
                printf("%s\n",[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);fflush(stdout);
                if(getenv("O3DV_TEST_CANCEL_AFTER_READY") && [state[@"phase"] isEqual:@"ready"])cancel.cancelled=YES;
            } cancellation:cancel error:&error];
        if(!ok) {fprintf(stderr,"%s:%ld %s\n",error.domain.UTF8String,(long)error.code,error.localizedDescription.UTF8String);return 1;}
    }
    return 0;
}
