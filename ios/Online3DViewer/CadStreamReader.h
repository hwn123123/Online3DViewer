#import <Foundation/Foundation.h>
#import "RhinoStreamReader.h"
NS_ASSUME_NONNULL_BEGIN
@interface CadStreamReader : NSObject
+ (BOOL)convertFile:(NSString *)source toDirectory:(NSString *)directory
          progress:(void (^)(NSDictionary<NSString *,id> *))progress
      cancellation:(RhinoReadCancellation *)cancellation
             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(convert(file:directory:progress:cancellation:));
@end
NS_ASSUME_NONNULL_END
