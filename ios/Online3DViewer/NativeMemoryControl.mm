#import "NativeMemoryControl.h"
#include "NativeMemory.hpp"
@implementation NativeMemoryControl
+ (void)setPressureLevel:(NSInteger)level { o3dv::MemoryPressure().store(int(level),std::memory_order_relaxed); }
+ (NSDictionary<NSString *,id> *)snapshot {
    auto m=o3dv::SampleMemory();
    NSString *cache=[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSNumber *storage=[NSFileManager.defaultManager attributesOfFileSystemForPath:cache error:nil][NSFileSystemFreeSize]?:@0;
    bool low=m.pressure>0 || (m.availableKnown && m.available<256*o3dv::MemoryMiB);
    size_t geometry=low?24:64;
    if (!low && m.availableKnown && m.available >= 1536*o3dv::MemoryMiB) geometry=192;
    else if (!low && m.availableKnown && m.available >= 768*o3dv::MemoryMiB) geometry=96;
    return @{@"footprintBytes":@(m.footprint),@"residentBytes":@(m.resident),@"availableBytes":@(m.available),@"freeStorageBytes":storage,
        @"pressure":@(m.pressure),@"geometryBytes":@(geometry*o3dv::MemoryMiB),
        @"textureBytes":@((low?12:24)*o3dv::MemoryMiB),@"framePixels":@(low?1500000:3500000)};
}
@end
