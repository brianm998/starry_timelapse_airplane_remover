// GPUOps_C.cpp — registration point for the optional GPU backend. See GPUOps_C.h.
#include "GPUOps_C.h"

#include <atomic>

// Written once during setup (GPUOps.swift, mirroring ImageCache_C.cpp's loader)
// and read from every warp/merge call site. Atomic for the same reason as
// ImageCache_C.cpp's g_imageLoader: "written once" is a convention, not
// something the type system enforces.
static std::atomic<GPUWarpFunc> g_gpuWarp{nullptr};
static std::atomic<GPUMedianMergeFunc> g_gpuMedianMerge{nullptr};

void gpu_ops_set_handlers(GPUWarpFunc warp, GPUMedianMergeFunc medianMerge) {
    g_gpuWarp.store(warp, std::memory_order_release);
    g_gpuMedianMerge.store(medianMerge, std::memory_order_release);
}

bool gpu_ops_warp_available(void) {
    return g_gpuWarp.load(std::memory_order_acquire) != nullptr;
}

bool gpu_ops_median_merge_available(void) {
    return g_gpuMedianMerge.load(std::memory_order_acquire) != nullptr;
}

// Not part of the public C API in GPUOps_C.h — these two hand out the actual
// function pointer rather than just whether one is set, which only
// ImageAligner.cpp needs (to make the call), so they are forward-declared
// there directly instead of adding them to the header Swift sees.
extern "C" GPUWarpFunc gpu_ops_get_warp(void) {
    return g_gpuWarp.load(std::memory_order_acquire);
}
extern "C" GPUMedianMergeFunc gpu_ops_get_median_merge(void) {
    return g_gpuMedianMerge.load(std::memory_order_acquire);
}
