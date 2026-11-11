#import "RhinoStreamReader.h"

NS_ASSUME_NONNULL_BEGIN
/// Device-local OBJ/FBX parsing. Writes the same block manifest as the Rhino reader.
@interface MeshStreamReader : NSObject
+ (BOOL)convertFile:(NSString *)source
       toDirectory:(NSString *)directory
          progress:(void (^)(NSDictionary<NSString *, id> *))progress
      cancellation:(RhinoReadCancellation *)cancellation
             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(convert(file:directory:progress:cancellation:));
@end
NS_ASSUME_NONNULL_END
