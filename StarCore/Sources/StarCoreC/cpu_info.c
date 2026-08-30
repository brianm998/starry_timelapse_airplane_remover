#include "include/StarCoreC.h"
#include <stdint.h>

#if defined(__APPLE__)

#include <sys/sysctl.h>
#include <string.h>

// hw.physicalcpu, not hw.ncpu: ncpu is the logical count, which on a hyperthreaded machine
// is twice the cores.  hw.physicalcpu rather than hw.physicalcpu_max, because it reports
// the cores this process may actually run on — a machine with some cores offline should
// not be told it has them.
uint32_t star_physical_core_count(void) {
    int count = 0;
    size_t size = sizeof(count);
    if (sysctlbyname("hw.physicalcpu", &count, &size, NULL, 0) != 0) return 0;
    if (count <= 0) return 0;
    return (uint32_t)count;
}

#elif defined(__linux__)

#include <stdio.h>

// /proc/cpuinfo lists one block per *logical* cpu, and the two threads of one core share a
// (physical id, core id) pair.  Counting the distinct pairs is therefore the core count.
//
// Not every kernel and architecture emits those two fields — ARM commonly does not — and
// in that case this returns 0 and the caller falls back to the logical count, which is the
// right answer on a machine with no SMT to discount.
#define STAR_MAX_CORES 4096

uint32_t star_physical_core_count(void) {
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f) return 0;

    // Packed as (physical id << 16 | core id).  Both are small on any real machine; a value
    // that did not fit would collide and undercount, which is safer than overcounting.
    static uint32_t seen[STAR_MAX_CORES];
    uint32_t found = 0;
    long physicalID = -1, coreID = -1;

    char line[512];
    while (fgets(line, sizeof(line), f)) {
        long value = 0;
        if (sscanf(line, "physical id : %ld", &value) == 1) {
            physicalID = value;
        } else if (sscanf(line, "core id : %ld", &value) == 1) {
            coreID = value;
        }
        if (physicalID < 0 || coreID < 0) continue;

        uint32_t key = ((uint32_t)physicalID << 16) | ((uint32_t)coreID & 0xFFFF);
        physicalID = -1;
        coreID = -1;

        int isNew = 1;
        for (uint32_t i = 0; i < found; i++) {
            if (seen[i] == key) { isNew = 0; break; }
        }
        if (isNew && found < STAR_MAX_CORES) seen[found++] = key;
    }
    fclose(f);
    return found;
}

#elif defined(_WIN32)

#include <windows.h>
#include <stdlib.h>

// One SYSTEM_LOGICAL_PROCESSOR_INFORMATION entry per core is tagged RelationProcessorCore,
// whether or not that core is hyperthreaded, so counting those entries is the core count.
uint32_t star_physical_core_count(void) {
    DWORD length = 0;
    if (GetLogicalProcessorInformation(NULL, &length) ||
        GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
        return 0;
    }
    SYSTEM_LOGICAL_PROCESSOR_INFORMATION *buffer = malloc(length);
    if (!buffer) return 0;
    if (!GetLogicalProcessorInformation(buffer, &length)) {
        free(buffer);
        return 0;
    }
    uint32_t cores = 0;
    DWORD count = length / (DWORD)sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION);
    for (DWORD i = 0; i < count; i++) {
        if (buffer[i].Relationship == RelationProcessorCore) cores++;
    }
    free(buffer);
    return cores;
}

#else

uint32_t star_physical_core_count(void) { return 0; }

#endif
