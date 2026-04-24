#include "include/StarCoreC.h"
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <unistd.h>

uint64_t star_available_system_memory(void) {
    vm_statistics64_data_t vmStats;
    mach_msg_type_number_t infoCount = HOST_VM_INFO64_COUNT;
    kern_return_t result = host_statistics64(
        mach_host_self(),
        HOST_VM_INFO64,
        (host_info64_t)&vmStats,
        &infoCount
    );
    if (result != KERN_SUCCESS) {
        return 0;
    }
    uint64_t pageSize = (uint64_t)getpagesize();
    return (vmStats.free_count + vmStats.inactive_count) * pageSize;
}
