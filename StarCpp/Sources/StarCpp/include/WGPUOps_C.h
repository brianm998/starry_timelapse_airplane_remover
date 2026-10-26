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
