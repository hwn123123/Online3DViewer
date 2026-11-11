#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NativeMemoryControl : NSObject
+ (NSDictionary<NSString *,id> *)snapshot;
+ (void)setPressureLevel:(NSInteger)level;
@end
NS_ASSUME_NONNULL_END
