#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RhinoReadCancellation : NSObject
@property (atomic) BOOL cancelled;
/// Optional lower budget for native atomic decoders; zero uses the reader's default.
@property (atomic) NSUInteger decoderBudgetBytes;
@end

@interface RhinoStreamReader : NSObject
+ (BOOL)convertFile:(NSString *)source
       toDirectory:(NSString *)directory
          progress:(void (^)(NSDictionary<NSString *, id> *))progress
      cancellation:(RhinoReadCancellation *)cancellation
             error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(convert(file:directory:progress:cancellation:));
@end

NS_ASSUME_NONNULL_END
