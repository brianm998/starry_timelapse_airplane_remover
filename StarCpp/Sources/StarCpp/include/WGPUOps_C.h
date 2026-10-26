// WGPUOps_C.h — the wgpu-native (WebGPU) GPU backend: Vulkan on Linux, Direct3D 12 on Windows, and
// Metal on macOS when the Metal backend (GPUOps.swift) is not the one in use.
//
// Same seam as GPUOps_C.h: the warp and aligned-merge functions below have exactly the handler
// signatures GPUWarpFunc / GPUAlignedMergeFunc declare, return false for anything unsupported, and
// leave the CPU path to do the work. They are exported by name (not only through
// gpu_ops_set_handlers) so a test can run this backend on a machine whose registered backend is another.
//
// Built only when wgpu-native is present (wgpu/fetch.sh; see StarCpp/Package.swift), which defines
// STAR_HAVE_WGPU. Without it every function here exists and says "not available".
#pragma once

#include "starcpp_bridge_types.h"
#include "GPUOps_C.h"

#ifdef __cplusplus
extern "C" {
#endif

// Whether this build has wgpu-native at all (compile-time fact, no device is touched).
bool wgpu_ops_compiled_in(void);

// Whether the process asked for this backend (STAR_WGPU set). It is opt-in until it has been measured on
// real hardware; without it nothing here touches a GPU driver and `wgpu_ops_available` is false.
bool wgpu_ops_opted_in(void);

// Finds an adapter and creates the device, once; later calls return the first answer.
// A software adapter (lavapipe, WARP) is refused unless STAR_WGPU_ALLOW_CPU_ADAPTER=1 is set — it
// would be slower than the CPU path it replaces, and is wanted only by tests and CI.
// STAR_WGPU_BACKEND=vulkan|dx12|metal restricts the instance to one backend.
bool wgpu_ops_available(void);

// "<adapter description> (<backend>, <adapter type>)", or NULL when not available. Owned by the
// library; valid for the life of the process.
const char *wgpu_ops_device_description(void);

// Whether the device can run the fused aligned merge: it needs 18 storage buffers in one stage.
bool wgpu_ops_aligned_merge_supported(void);

// Where the latest warp or aligned merge spent its time, in seconds, into `seconds[6]`:
// [0] building the tile table and parameters, [1] creating and filling the source buffers,
// [2] recording and validating the command buffer, [3] the GPU run (submit until the result is mapped),
// [4] copying the result out, [5] the whole call. False when there is no backend or nothing has run.
bool wgpu_ops_last_timing(double *seconds);

// Frees the buffers kept between operations (the pool is capped by STAR_WGPU_POOL_MB, default 4096).
// For memory pressure; does nothing when there is no backend.
void wgpu_ops_trim_pool(void);

// Whether the device can run the standalone median merge: 20 storage buffers in one stage.
bool wgpu_ops_median_merge_supported(void);

// GPUMedianMergeFunc's contract (GPUOps_C.h): a sigma-clipped median over `count` (1...17) same-shaped,
// same-typed sources, index 0 first, honouring the coverage-misses plane exactly. Float, not the CPU
// kernel's double Welford recurrence, like the Metal one.
bool wgpu_ops_median_merge(MatWrapperRef *sources, int count, MatWrapperRef misses,
                           double outlierThreshold, bool includeAll, MatWrapperRef dst);

// GPUSiftPyramidFunc's contract (GPUOps_C.h): the Gaussian scale-space pyramid SIFTDetector.cpp needs, as
// nOctaves * (nOctaveLayers + 3) new CV_32FC1 Mats in `outPyramid` (the caller releases them). False when the
// pyramid would not fit the device (STAR_WGPU_PYRAMID_MB, default 3072) or anything else cannot be done.
bool wgpu_ops_sift_pyramid(MatWrapperRef base, bool doubleImageSize, double sigma, int nOctaves,
                           int nOctaveLayers, MatWrapperRef *outPyramid);

// GPUAkazePyramidFunc's contract (GPUOps_C.h): the nonlinear diffusion scale-space pyramid
// AKAZEDetector.cpp needs, as `levelCount` new CV_32FC1 Lt Mats and as many Lsmooth Mats (the caller
// releases them). False when it would not fit the device (STAR_WGPU_PYRAMID_MB) or cannot be done.
bool wgpu_ops_akaze_pyramid(MatWrapperRef img, float soffset, const GPUAkazeLevelInfo *levels, int levelCount,
                            const int *stepCounts, const float *tsteps, int tstepsCount, float kcontrastBase,
                            MatWrapperRef *outLt, MatWrapperRef *outLsmooth);

bool wgpu_ops_warp(MatWrapperRef src, const double *homography, MatWrapperRef dst);

bool wgpu_ops_aligned_merge(MatWrapperRef base, MatWrapperRef *neighbours, int neighbourCount,
                            const double *homographies, double outlierThreshold, bool includeAll,
                            MatWrapperRef dst);

// Registers this backend's handlers with gpu_ops_set_handlers() when opted in. It does not probe: the
// handlers start the device on first use and return false when there is none. Returns whether it
// registered. Call only when no other backend has been registered.
bool wgpu_ops_register(void);

#ifdef __cplusplus
}
#endif
