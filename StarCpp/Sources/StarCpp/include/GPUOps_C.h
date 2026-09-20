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

// A GPU-accelerated ALIGNED merge for one frame: batches every neighbour's warp
// plus the final sigma-clipped median merge onto a single Metal command buffer,
// replacing what would otherwise be `neighbourCount * 2 + 1` separate GPU
// round-trips (GPUWarpFunc for the image, again for coverage, per neighbour,
// then GPUMedianMergeFunc) with exactly one. See GPU_MERGE_BATCHING_FIX.md for
// why that round-trip count mattered: each one pays a fixed allocate/submit/
// wait/readback cost that measured larger than the GPU kernel work itself, so
// paying it 17 times per frame (star's default 8 neighbours) turned a genuine
// win (the SIFT/AKAZE pyramid builders, which batch the same way) into a
// measured 2.35x regression versus the CPU path.
//
// `base` is the always-included base frame — it is never warped, exactly like
// every other merge entry point in this header. `neighbours` is an array of
// `neighbourCount` already-decoded neighbour images, each with the same rows/
// cols/type as `base` (the caller filters out any that do not match before
// calling this — there is no partial-geometry handling here). `homographies`
// is the flattened row-major 3x3 (9 doubles) FORWARD homography (src -> dst,
// the same convention GPUWarpFunc takes) for neighbour i at
// `homographies[i*9 .. i*9+8]`.
//
// `outlierThreshold`/`includeAll` are the same sigma-clip parameters
// GPUMedianMergeFunc takes, and the coverage-misses accounting this computes
// internally (one count per pixel of how many neighbours' warps did not reach
// it) follows the exact CoverageMisses contract medianMergeTyped uses — see
// GPUMedianMergeFunc's doc comment above. `dst` is a pre-allocated MatWrapper
// matching base's rows/cols/type; the callee fills it with the final merged
// result, equivalent to warping every neighbour (GPUWarpFunc), accumulating
// their coverage misses, and handing base + every warp to GPUMedianMergeFunc.
//
// `1 + neighbourCount` must not exceed 17, the same fixed cap
// GPUMedianMergeFunc already has (its kernel's `float v[17]` — this reuses that
// same median-merge kernel internally, unmodified, over GPU-resident buffers).
//
// Returns false on any failure or unsupported case (channel count, pixel
// depth, too many sources, oversized frame); the caller then redoes the WHOLE
// frame's merge on the CPU path (each neighbour's own CPU warp, then
// medianMergeTyped) — there is no partial fallback once a batched dispatch
// chain is committed to, matching the convention SIFTDetector.cpp /
// AKAZEDetector.cpp already use for their own GPU pipelines.
typedef bool (*GPUAlignedMergeFunc)(MatWrapperRef base,
                                    MatWrapperRef *neighbours, int neighbourCount,
                                    const double *homographies,
                                    double outlierThreshold, bool includeAll,
                                    MatWrapperRef dst);

// Register the GPU backend. Any pointer may be NULL, meaning that operation
// has no GPU implementation; gpu_ops_warp_available() /
// gpu_ops_median_merge_available() / gpu_ops_aligned_merge_available() report
// false for it and every caller uses the CPU path. Intended to be called once,
// at process startup — mirrors image_cache_set_loader's pattern in
// ImageCache_C.h.
//
// `alignedMerge` is registered here, alongside warp/medianMerge, rather than
// via its own gpu_ops_set_*_handler call (the way the SIFT/AKAZE pyramid
// builders are below) because it is gated by the same Config.useGPU flag as
// warp/medianMerge, not a separate one — ia_align_and_median_merge decides
// whether to call it exactly the way it already decides for GPUWarpFunc.
void gpu_ops_set_handlers(GPUWarpFunc warp, GPUMedianMergeFunc medianMerge,
                          GPUAlignedMergeFunc alignedMerge);

// Whether a warp/median-merge/aligned-merge GPU handler is currently
// registered. This is NOT the same question as "does Config.useGPU say yes" —
// that decision is made in Swift, inside the registered handler itself (see
// GPUOps.swift), which returns false immediately without doing any GPU work
// when the user has turned GPU acceleration off. These functions only answer
// "is there anywhere to even ask."
bool gpu_ops_warp_available(void);
bool gpu_ops_median_merge_available(void);
bool gpu_ops_aligned_merge_available(void);

// Builds the Gaussian scale-space pyramid a from-scratch reimplementation of
// SIFT needs — see siftDetectAndCompute in ImageAligner.cpp, which exists
// because OpenCV's own SIFT internals are not exposed by any public API, so
// there is no seam to hand a GPU-built pyramid into "OpenCV's real SIFT."
// This covers exactly the two steps OpenCV's own profiling puts at ~100% of
// SIFT's cost: `createInitialImage`'s upscale-and-blur and
// `buildGaussianPyramid`'s per-octave/layer blur cascade. Everything after
// (DoG, extrema, orientation, descriptors) is comparatively cheap — O(pixels)
// once versus O(pixels) times 55 blurs — and stays on the CPU as a faithful,
// unhurried port instead.
//
// `base` is CV_32FC1: the plain float cast of the CV_8U detection image, with
// no blur and no upscale applied yet (i.e. SIFT's `gray_fpt`, before
// `createInitialImage` touches it). `doubleImageSize` mirrors SIFT's
// `firstOctave < 0` case; this codebase never supplies pre-computed keypoints
// to SIFT, so it is always true in practice, but the handler must honour it
// either way. `sigma` is SIFT's own sigma parameter (1.6 by default).
//
// `outPyramid` must point to a caller-allocated array of exactly
// `nOctaves * (nOctaveLayers + 3)` slots, laid out exactly like OpenCV's own
// `pyr[o*(nOctaveLayers+3) + i]` — octave-major, layer-minor. On success every
// slot holds a newly allocated CV_32FC1 MatWrapperRef (caller must release
// each one); on failure the array is left untouched and every slot must be
// treated as unset. Returns false on any failure or unsupported case — the
// caller then abandons the custom pipeline entirely and calls real
// `cv::SIFT::create()->detectAndCompute()`, since there is no partial fallback
// once a hand-ported pipeline is committed to.
typedef bool (*GPUSiftPyramidFunc)(MatWrapperRef base, bool doubleImageSize,
                                   double sigma, int nOctaves, int nOctaveLayers,
                                   MatWrapperRef *outPyramid);

// Registers (or clears, with NULL) the SIFT pyramid GPU backend. Separate
// from gpu_ops_set_handlers/warp/median-merge above because it is gated by
// its own Config flag (Config.useGPUForSIFT, off by default) rather than the
// general useGPU — see that property's doc comment for why.
void gpu_ops_set_sift_pyramid_handler(GPUSiftPyramidFunc handler);
bool gpu_ops_sift_pyramid_available(void);

// One level of the AKAZE nonlinear scale-space pyramid's sizing/timing
// schedule — see GPUAkazePyramidFunc below. `width`/`height` are this level's
// image size; `newOctave` (0/1, plain int for C ABI compatibility) is true
// iff this level starts a new octave, i.e. its Lt must come from *halving*
// the previous level's Lt (cv::INTER_AREA, an exact 2x box-filter average)
// rather than copying it — matching create_nonlinear_scale_space's own
// `if (e.octave > evolution[i-1].octave)` branch.
typedef struct {
    int width;
    int height;
    int newOctave;
} GPUAkazeLevelInfo;

// Builds the nonlinear diffusion scale-space pyramid a from-scratch
// reimplementation of AKAZE needs — see AKAZEDetector.cpp, which exists for
// the same reason SIFTDetector.cpp does: OpenCV's AKAZE internals are not
// exposed by any public API, so there is no seam to hand a GPU-built pyramid
// into "OpenCV's real AKAZE." This covers exactly the per-level image work
// GPU_ACCELERATION_PROPOSAL.md and GPU_IMPLEMENTATION_GUIDE.md identify as
// the cost: the 5x5 Gaussian blur, Scharr derivatives and Perona-Malik G2
// diffusivity computed once per level, and the Fast Explicit Diffusion (FED)
// stencil steps between levels. Everything numerically fiddly and *not*
// image-sized work — the per-level dimension/sigma/etime schedule
// (Allocate_Memory_Evolution) and the FED step-count/step-size schedule
// (fed_tau_by_process_time's cosine/prime-permutation math) — is computed
// once on the CPU by shared code both backends call, and handed in here
// as `levels`/`tsteps`, so that dynamic-programming subtlety is never
// duplicated in Swift.
//
// `img` is CV_32FC1, range [0,1]: the plain grayscale float cast of the
// CV_8U detection image, with no blur applied yet (AKAZE's `prepareInputImage`
// output). `soffset` is AKAZE's base scale offset (1.6f by default) — the
// sigma this handler must use for `img`'s own initial 5x5-equivalent blur to
// produce level 0's Lt/Lsmooth (both equal at level 0, matching
// create_nonlinear_scale_space's `evolution[0].Lsmooth.copyTo(evolution[0].Lt)`).
//
// `levels`/`levelCount` describe every level including level 0. `tsteps` is
// the flattened, level-major concatenation of every level's FED step sizes
// (already halved — i.e. each entry is `tau * 0.5f`, exactly what
// non_linear_diffusion_step expects as its `step_size` argument); level 0 and
// any level that is a new octave's first sublevel still take FED steps like
// any other level past 0 (only level 0 itself takes none). `stepCounts` gives
// each level's share of `tsteps` in the same order (`stepCounts[0]` is always
// 0). `kcontrastBase` is the contrast factor computed once from `img` at full
// resolution (compute_kcontrast, before any per-octave decay) — the handler
// must multiply it by 0.75 at each level where `newOctave` is true, exactly
// matching create_nonlinear_scale_space's own `kcontrast *= 0.75f`.
//
// `outLt`/`outLsmooth` must each point to a caller-allocated array of exactly
// `levelCount` slots. On success every slot in both arrays holds a newly
// allocated CV_32FC1 MatWrapperRef (caller must release each one); on failure
// both arrays are left untouched. Returns false on any failure or unsupported
// case — the caller then abandons the custom pipeline entirely and calls real
// `cv::AKAZE::create()`, since there is no partial fallback once a hand-ported
// pipeline is committed to.
typedef bool (*GPUAkazePyramidFunc)(MatWrapperRef img, float soffset,
                                    const GPUAkazeLevelInfo *levels, int levelCount,
                                    const int *stepCounts, const float *tsteps, int tstepsCount,
                                    float kcontrastBase,
                                    MatWrapperRef *outLt, MatWrapperRef *outLsmooth);

// Registers (or clears, with NULL) the AKAZE pyramid GPU backend. Gated by
// its own Config flag (Config.useGPUForAKAZE, off by default — see that
// property's doc comment), separate from both Config.useGPU and
// Config.useGPUForSIFT.
void gpu_ops_set_akaze_pyramid_handler(GPUAkazePyramidFunc handler);
bool gpu_ops_akaze_pyramid_available(void);

#ifdef __cplusplus
}
#endif
