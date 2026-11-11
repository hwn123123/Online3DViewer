#import "RhinoStreamReader.h"

NS_ASSUME_NONNULL_BEGIN
/// Bounded, device-local binary/ASCII STL reader. Never retains the whole mesh.
@interface StlStreamReader : NSObject
+ (BOOL)convertFile:(NSString *)source
       toDirectory:(NSString *)directory
          progress:(void (^)(NSDictionary<NSString *, id> *))progress
      cancellation:(RhinoReadCancellation *)cancellation
             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(convert(file:directory:progress:cancellation:));
@end
NS_ASSUME_NONNULL_END
