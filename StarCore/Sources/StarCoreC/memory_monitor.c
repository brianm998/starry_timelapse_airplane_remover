#include "include/StarCoreC.h"
#include <stdint.h>

#if defined(__APPLE__)

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/vm_statistics.h>
#include <unistd.h>

// What the machine can still hand out without compressing or swapping something that is
// currently live: free pages, purgeable pages, and the file-backed cache.
//
// This used to be `free_count + inactive_count`, and that number is not availability. The
// inactive queue is mostly *anonymous* (dirty, app-owned) pages that happen not to have
// been touched recently; reclaiming one means compressing it or writing it to swap, which
// is the failure mode this probe exists to detect. So the figure stayed comfortable right
// up to the moment the machine died.
//
// Measured on a 128GB machine at moderate load, with 58.8GB anonymous and 8.8GB already
// held by the compressor: the old formula reported 69.1GB available and this one reports
// 51.0GB. It cross-checks against the total — 128 - internal(58.8) - compressor(8.8) -
// wired(9.6) = 50.8GB — and against Activity Monitor, which counts exactly these three
// buckets as Free plus Cached Files.
//
// Under the load that motivated this the gap is far wider than 18GB, because everything
// star allocates is anonymous: a run holding 85GB of frame buffers puts most of that 85GB
// on the inactive queue and the old formula read it back as free space.
//
// `free_count` already includes `speculative_count`, so speculative pages are counted
// once, here, and not added again. File-backed pages are counted as available even when
// dirty: they may need writing back first, but they are reclaimable without touching swap,
// and the kernel takes them before it compresses anything.
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
    uint64_t pages = (uint64_t)vmStats.free_count
                   + (uint64_t)vmStats.purgeable_count
                   + (uint64_t)vmStats.external_page_count;
    return pages * pageSize;
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
// getpagesize(). The include above this file's __APPLE__ branch does not reach here, so
// without this the call is an implicit declaration — an error under C99 and later, which
// is what broke the Linux build.
#include <unistd.h>

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
