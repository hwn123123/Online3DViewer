#import <Foundation/Foundation.h>
#import "RhinoCacheBatcher.h"
@implementation RhinoReadCancellation
@end
int main(int argc,char **argv) { @autoreleasepool {
 if(argc!=3)return 2;
 NSError *error=nil;RhinoReadCancellation *c=[RhinoReadCancellation new];
 if(getenv("O3DV_TEST_CANCEL"))c.cancelled=YES;
 BOOL ok=[RhinoCacheBatcher batchDirectory:[NSString stringWithUTF8String:argv[1]] toDirectory:[NSString stringWithUTF8String:argv[2]] progress:^(NSUInteger n,NSUInteger total){ if(n==total)printf("%lu/%lu\n",(unsigned long)n,(unsigned long)total); } cancellation:c error:&error];
 if(!ok)fprintf(stderr,"%s\n",error.localizedDescription.UTF8String);
 return ok?0:1;
}}
