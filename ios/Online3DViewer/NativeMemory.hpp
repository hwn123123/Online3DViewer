#pragma once
#include <atomic>
#include <cstddef>
#include <mach/mach.h>
#include <os/proc.h>
#include <TargetConditionals.h>

namespace o3dv {
constexpr size_t MemoryMiB=1024*1024;
inline std::atomic<int> &MemoryPressure() { static std::atomic<int> value{0};return value; }
struct MemorySnapshot { size_t footprint=0,resident=0,available=0;int pressure=0;bool availableKnown=false; };
inline MemorySnapshot SampleMemory() {
    MemorySnapshot result;task_vm_info_data_t info={};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS) {
        result.footprint=info.phys_footprint;result.resident=info.resident_size;
    }
    #if TARGET_OS_IOS
    result.available=os_proc_available_memory();
    result.availableKnown=true;
    #endif
    result.pressure=MemoryPressure().load(std::memory_order_relaxed);return result;
}
}
