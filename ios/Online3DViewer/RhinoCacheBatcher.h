#import <Foundation/Foundation.h>
#import "RhinoStreamReader.h"

NS_ASSUME_NONNULL_BEGIN
@interface RhinoCacheBatcher : NSObject
+ (BOOL)needsBatching:(NSString *)directory;
+ (BOOL)batchDirectory:(NSString *)source toDirectory:(NSString *)destination
             progress:(void (^)(NSUInteger, NSUInteger))progress
         cancellation:(RhinoReadCancellation *)cancellation error:(NSError **)error
    NS_SWIFT_NAME(batch(directory:destination:progress:cancellation:));
@end
NS_ASSUME_NONNULL_END
