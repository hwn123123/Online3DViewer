#pragma once
#include <mutex>

namespace o3dv {
// Cancelling and immediately opening another model must not overlap two scene allocations.
inline std::mutex &NativeReadMutex() {
    static std::mutex mutex;
    return mutex;
}
}
