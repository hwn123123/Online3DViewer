#import <Foundation/Foundation.h>
#import "MeshStreamReader.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: mesh-stream input.obj/input.fbx cache-directory\n"); return 2; }
        NSError *error = nil;
        RhinoReadCancellation *cancel=[RhinoReadCancellation new];
        if(getenv("O3DV_TEST_CANCEL")) cancel.cancelled=YES;
        BOOL success = [MeshStreamReader convertFile:[NSString stringWithUTF8String:argv[1]]
            toDirectory:[NSString stringWithUTF8String:argv[2]]
            progress:^(NSDictionary *status) {
                if(![status[@"phase"] isEqual:@"parsing"]) { printf("%s objects=%ld\n",[status[@"phase"] UTF8String],(long)[status[@"objects"] integerValue]);fflush(stdout); }
                if(getenv("O3DV_TEST_CANCEL_AFTER_READY") && [status[@"phase"] isEqual:@"ready"]) cancel.cancelled=YES;
            } cancellation:cancel error:&error];
        if (!success) { fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);return 1; }
    }
    return 0;
}
