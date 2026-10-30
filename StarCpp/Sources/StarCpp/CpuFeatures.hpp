// CpuFeatures.hpp — what the x86-64 kernels that are compiled for AVX2 need to know about the
// machine they find themselves on.
//
// star ships one binary per architecture with no -march, so the baseline is SSE2 on Intel and
// NEON on Apple silicon.  A kernel that is faster with a wider unit is compiled for it
// (`STAR_AVX2`) and chosen at run time with `cpuRunsAvx2`.
#pragma once

#if defined(__x86_64__) && defined(__has_include)
#if __has_include(<cpuid.h>) && __has_include(<immintrin.h>)
#include <cpuid.h>
#include <immintrin.h>
#define STAR_X86_AVX2_KERNELS 1
#endif
#endif

#ifdef STAR_X86_AVX2_KERNELS

#define STAR_AVX2 __attribute__((target("avx2")))
#define STAR_AVX2_INLINE __attribute__((target("avx2"), always_inline)) inline

// Whether this CPU, under this OS, runs AVX2: the CPU says so, and the OS has enabled
// the YMM state (XCR0 bits 1 and 2).  Done with cpuid directly rather than
// __builtin_cpu_supports, which needs a runtime library not every toolchain star builds
// with provides.  Rosetta reports no AVX and so lands on the baseline kernels.
inline bool cpuRunsAvx2() {
    static const bool runs = [] {
        unsigned a = 0, b = 0, c = 0, d = 0;
        if (!__get_cpuid(1, &a, &b, &c, &d)) return false;
        if (!(c & (1u << 27)) || !(c & (1u << 28))) return false;   // OSXSAVE, AVX
        unsigned lo = 0, hi = 0;
        __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
        if ((lo & 6u) != 6u) return false;
        if (__get_cpuid_max(0, nullptr) < 7) return false;
        __cpuid_count(7, 0, a, b, c, d);
        return (b & (1u << 5)) != 0;                                // AVX2
    }();
    return runs;
}

#endif  // STAR_X86_AVX2_KERNELS
