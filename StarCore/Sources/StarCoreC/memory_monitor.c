#include "include/StarCoreC.h"
#include <stdint.h>

#if defined(__APPLE__)

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

#elif defined(__linux__)

#include <stdio.h>

// Read MemAvailable from /proc/meminfo — the kernel's best estimate of how
// much memory can be allocated without swapping (free + reclaimable caches).
uint64_t star_available_system_memory(void) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;

    char key[64];
    uint64_t value;
    char unit[16];
    while (fscanf(f, "%63s %llu %15s\n", key, (unsigned long long *)&value, unit) >= 2) {
        if (__builtin_strcmp(key, "MemAvailable:") == 0) {
            fclose(f);
            return value * 1024ULL;   // /proc/meminfo reports kB
        }
    }
    fclose(f);
    return 0;
}

#else

// Unknown platform — caller will fall back to a default estimate.
uint64_t star_available_system_memory(void) { return 0; }

#endif

// --- Per-process footprint --------------------------------------------------

#if defined(__APPLE__)

#include <mach/task.h>
#include <mach/task_info.h>

uint64_t star_process_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (uint64_t)info.phys_footprint;
}

#elif defined(__linux__)

#include <stdio.h>

uint64_t star_process_footprint(void) {
    // statm field 2 is resident pages.
    FILE *f = fopen("/proc/self/statm", "r");
    if (!f) return 0;
    unsigned long long total = 0, resident = 0;
    int read = fscanf(f, "%llu %llu", &total, &resident);
    fclose(f);
    if (read < 2) return 0;
    return (uint64_t)resident * (uint64_t)getpagesize();
}

#elif defined(_WIN32)

#include <windows.h>
#include <psapi.h>

uint64_t star_process_footprint(void) {
    PROCESS_MEMORY_COUNTERS pmc;
    if (!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) return 0;
    return (uint64_t)pmc.WorkingSetSize;
}

#else

uint64_t star_process_footprint(void) { return 0; }

#endif
