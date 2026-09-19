// GPUOps_C.h — Pure C API for the optional GPU-accelerated warp/median-merge
// kernels used by ImageAligner.cpp.
//
// StarCpp is pure C++ (no ObjC++ — see StarCpp/Package.swift), and Metal is a
// Swift/Objective-C API, so this file does not touch Metal at all. It only
// declares a registration point: StarCppBridge/GPUOps.swift builds the actual
// Metal device/pipelines and calls gpu_ops_set_handlers() once, at process
// startup, exactly the way ImageCache_C.h's loader callback works. Everything
// below is a thin, testable seam — a CPU implementation of warp and median
// merge always exists in ImageAligner.cpp regardless of whether a GPU backend
// is ever registered, and every call here can fail (return false) and hand
// control back to it.
#pragma once

#include "starcpp_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// A GPU-accelerated bilinear warp matching
// cv::warpPerspective(src, dst, H, src.size(), INTER_LINEAR, BORDER_TRANSPARENT):
// every destination pixel the warp does not reach must come back exactly zero,
// which is what lets the merge tell "not sampled here" from "really black."
// `dst` is a pre-allocated MatWrapper with the same rows/cols/type as `src`;
// the callee fills it. `homography` points at the row-major 3x3 matrix as 9
// doubles (h00 h01 h02 h10 h11 h12 h20 h21 h22).
//
// Returns false on any failure or unsupported case (channel count, pixel
// depth, oversized frame — see GPUOps.swift for what it actually supports);
// the caller then runs the CPU warp instead and `dst`'s contents are not
// otherwise meaningful.
typedef bool (*GPUWarpFunc)(MatWrapperRef src, const double *homography,
                            MatWrapperRef dst);

// A GPU-accelerated sigma-clipped median merge across `count` same-shaped,
// same-typed `sources` (index 0 is always the base image). `misses`, when
// non-NULL, is a single-channel 8-bit plane the same size as one source:
// misses[p] gives how many of the FIRST misses[p] sources (in array order)
// have no sample at pixel p — the exact CoverageMisses contract
// medianMergeTyped uses in ImageAligner.cpp, and it must be honoured exactly
// or the black-border-on-edge-frames bug that plane exists to prevent comes
// back. `misses` is NULL exactly when includeAll is true. `dst` is a
// pre-allocated MatWrapper with the same rows/cols/type as the sources.
//
// Unlike medianMergeTyped's double-precision Welford recurrence, this is
// expected to compute mean/variance with exact integer arithmetic (Apple
// GPUs have no fp64, and n <= 17 with values <= 65535 fit exactly in
// uint32/uint64). That is a small, deliberate, and DOCUMENTED difference from
// the CPU kernel's output — see GPU_IMPLEMENTATION_GUIDE.md ยง2 — not a bug to
// fix by matching bytes here.
//
// Returns false on any failure or unsupported case; the caller falls back to
// medianMergeTyped.
typedef bool (*GPUMedianMergeFunc)(MatWrapperRef *sources, int count,
                                   MatWrapperRef misses,
                                   double outlierThreshold, bool includeAll,
                                   MatWrapperRef dst);

// Register the GPU backend. Either pointer may be NULL, meaning that
// operation has no GPU implementation; gpu_ops_warp_available() /
// gpu_ops_median_merge_available() report false for it and every caller uses
// the CPU path. Intended to be called once, at process startup — mirrors
// image_cache_set_loader's pattern in ImageCache_C.h.
void gpu_ops_set_handlers(GPUWarpFunc warp, GPUMedianMergeFunc medianMerge);

// Whether a warp/median-merge GPU handler is currently registered. This is
// NOT the same question as "does Config.useGPU say yes" — that decision is
// made in Swift, inside the registered handler itself (see GPUOps.swift),
// which returns false immediately without doing any GPU work when the user
// has turned GPU acceleration off. These two functions only answer "is there
// anywhere to even ask."
bool gpu_ops_warp_available(void);
bool gpu_ops_median_merge_available(void);

#ifdef __cplusplus
}
#endif
