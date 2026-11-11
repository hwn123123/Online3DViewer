#import <Foundation/Foundation.h>
#import "RhinoStreamReader.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) { fprintf(stderr, "usage: rhino-stream input.3dm cache-directory\n"); return 2; }
        NSError *error = nil;
        RhinoReadCancellation *cancellation=[RhinoReadCancellation new];
        BOOL success = [RhinoStreamReader convertFile:[NSString stringWithUTF8String:argv[1]]
            toDirectory:[NSString stringWithUTF8String:argv[2]]
            progress:^(NSDictionary *status) {
                if(getenv("O3DV_TEST_CANCEL_ON_INSTANCE") && [status[@"phase"] isEqual:@"instances"]) cancellation.cancelled=YES;
                NSInteger count = [status[@"objects"] integerValue];
                if (count <= 1 || count % 128 == 0 || [status[@"phase"] isEqual:@"complete"]) {
                    printf("%s objects=%ld geometry=%.2fMiB resident=%.2fMiB\n", [status[@"phase"] UTF8String],
                        (long)count, [status[@"geometryBytes"] doubleValue] / 1048576, [status[@"nativePeakMemoryBytes"] doubleValue] / 1048576);
                    fflush(stdout);
                }
            } cancellation:cancellation error:&error];
        if (!success) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    }
    return 0;
}
