// ImageAligner.h — Pure C API for image alignment operations
#pragma once

#include "starcpp_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Neighbor info for alignment ---
typedef struct {
    const char      *filename;
    const char      *maskFilename;  // nullable
    OCVFeatureSetRef keypoints;     // nullable, NOT owned (caller manages)
    int              frameIndex;
} AlignmentNeighborData;

// --- Median merge ---
//
// Neither of these warps anything, so every source covers every pixel and every
// value one of them holds is a real observation, a black one included.  That is
// the difference between them and ia_align_and_median_merge below, which has holes
// to describe and carries a coverage plane to describe them with.

// Merge images from filenames. Returns new MatWrapperRef (caller must release).
//
// useGPU asks for the Metal-accelerated median-merge kernel when one is
// registered and the machine has hardware for it (see GPUOps_C.h); the CPU
// kernel always runs otherwise, unchanged. GPU output uses exact integer
// arithmetic rather than the CPU kernel's double-precision Welford recurrence
// — a small, deliberate difference, not a bug — see GPU_IMPLEMENTATION_GUIDE.md.
MatWrapperRef ia_median_merge_filenames(const char **filenames, int count,
                                        double outlierThreshold, bool includeAll,
                                        bool useGPU);

// Merge a base image + additional filenames.
//
// Holding every source in memory at once costs (count + 1) x frameBytes, which is
// ~4.3GB for 17 sources at 42MP.  When that would exceed streamingThresholdBytes,
// each filename is instead decoded once into a raw scratch file under scratchDir
// and the merge reads back a band of rows at a time, bounding peak memory to a few
// hundred MB.  The output is bit-identical either way; the streaming path just
// trades disk I/O for RAM.
//
// streamingThresholdBytes <= 0 disables streaming.  scratchDir may be null, in
// which case the system temp directory is used.
//
// loadConcurrency is how many sources may be decoded (and, for the aligned merge,
// warped) at once on the all-resident path — 1 for the old one-at-a-time loop.  It
// cannot change the result: the merge sorts each pixel's samples before using them,
// so source order does not reach the answer, and the sources are collected in file
// order regardless.  The streaming path ignores it and stays serial: holding one
// source at a time is what it is for.
//
// useGPU: see ia_median_merge_filenames above. It only ever applies to the
// all-resident path — the streaming path (medianImageStreaming) stays
// CPU-only, since it exists for source counts too large to hold on the GPU
// (or in RAM) at once anyway.
MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll,
                                                    const char *scratchDir,
                                                    int64_t streamingThresholdBytes,
                                                    int loadConcurrency,
                                                    bool useGPU);

// --- Feature detection ---

// Detect features on a single frame. Returns new OCVFeatureSetRef on success, NULL on failure.
// errorMsg (if non-NULL) will be pointed to a static string on error.
OCVFeatureSetRef ia_find_features(MatWrapperRef baseImage, int frameIndex,
                                  FeatureMatchMethod matchMethod,
                                  MatWrapperRef mask, // nullable
                                  AlignmentType alignmentType,
                                  int maxKeypoints, bool writeDebugImages,
                                  // Earth alignment only: how far past the horizon to
                                  // reach INTO the sky for more keypoints.
                                  int groundHorizonExtension,
                                  // Sky alignment only: how many pixels to pull the sky
                                  // region UP away from the horizon before detecting, so
                                  // that neither the masked horizon's own step edge nor
                                  // terrain left inside a slightly-low mask can be
                                  // detected as stars.  0 disables it.
                                  int skyHorizonExtension,
                                  int baseImageDilateSize,
                                  int baseImageThresholdValue,
                                  // Fraction of full resolution to detect at; 1.0 (or
                                  // any value <= 0) detects at full size.  Keypoint
                                  // coordinates are always returned in full-resolution
                                  // space, but descriptors are computed at this scale,
                                  // so feature sets detected at different scales must
                                  // not be matched against each other.
                                  double detectionScale,
                                  // Sky alignment only, ignored for earth: use the
                                  // from-scratch GPU-accelerated SIFT reimplementation
                                  // (see SIFTDetector.cpp) instead of real cv::SIFT, when
                                  // a GPU pyramid handler is registered and this is true
                                  // (Config.useGPUForSIFT). Falls back to real cv::SIFT
                                  // — not partially, entirely — on any failure.
                                  bool useGPUForSift,
                                  // Earth alignment only, ignored for sky: the same idea
                                  // as useGPUForSift above, for the from-scratch
                                  // GPU-accelerated AKAZE reimplementation (see
                                  // AKAZEDetector.cpp / Config.useGPUForAKAZE). Falls
                                  // back to real cv::AKAZE — entirely, not partially —
                                  // on any failure.
                                  bool useGPUForAKAZE,
                                  const char **errorMsg);

// --- Test-only: the from-scratch SIFT port, without the cv::SIFT fallback ---
//
// Exposes SIFTDetector's two entry points directly so tests can compare them
// against each other and against real cv::SIFT (via ia_find_features with
// useGPUForSift=false) without depending on GPU availability to exercise the
// ported algorithm at all. `img` must be CV_8U grayscale (matching what
// ia_find_features hands cv::SIFT); `mask` may be null. Returns NULL if the
// requested backend (GPU pyramid) is unavailable — `reference` never fails
// this way, since it needs no GPU. Not meant to be a stable part of the C API
// otherwise; see GPUOpsTests.swift / SIFTDetectorTests.swift.
OCVFeatureSetRef ia_debug_sift_reference(MatWrapperRef img, MatWrapperRef mask, int nfeatures);
OCVFeatureSetRef ia_debug_sift_gpu(MatWrapperRef img, MatWrapperRef mask, int nfeatures);

// Real cv::SIFT::create(nfeatures)->detectAndCompute(img, mask, ...), called
// directly with none of ia_find_features's mask/scale preprocessing — the
// same raw-input contract as the two entries above, so all three can be
// compared on identical inputs to isolate "does the ported algorithm match
// real SIFT" from any question about the rest of ia_find_features's pipeline
// (which is unchanged and not what this is testing).
OCVFeatureSetRef ia_debug_sift_opencv(MatWrapperRef img, MatWrapperRef mask, int nfeatures);

// --- Test-only: the from-scratch AKAZE port, without the cv::AKAZE fallback ---
//
// Same shape as the SIFT trio above, for AKAZEDetector's two entry points plus
// real cv::AKAZE::create()->detect()/compute() (capped by `maxKeypoints` via
// cv::KeyPointsFilter::retainBest exactly as ImageAligner.cpp's earth branch
// already does, so all three are comparable). `img` must be CV_8U grayscale;
// `mask` may be null. `threshold` is the detector response cutoff (see
// ia_find_features's earth branch for the value this codebase actually uses).
// Returns NULL if the requested backend (GPU pyramid) is unavailable.
OCVFeatureSetRef ia_debug_akaze_reference(MatWrapperRef img, MatWrapperRef mask,
                                          int maxKeypoints, float threshold);
OCVFeatureSetRef ia_debug_akaze_gpu(MatWrapperRef img, MatWrapperRef mask,
                                    int maxKeypoints, float threshold);
OCVFeatureSetRef ia_debug_akaze_opencv(MatWrapperRef img, MatWrapperRef mask,
                                       int maxKeypoints, float threshold);

// --- Homography computation ---

// Compute homography for each neighbor. Returns count of warp infos written.
// outWarpInfos must point to an array of at least neighborCount elements.
// On error, returns 0 and sets errorMsg.
int ia_compute_homography(OCVFeatureSetRef baseKeypoints,
                          int frameIndex,
                          const AlignmentNeighborData *neighbors, int neighborCount,
                          FeatureMatchMethod matchMethod,
                          AlignmentType alignmentType,
                          int maxKeypoints, bool writeDebugImages,
                          AlignmentUpdateFunc updateHandler, void *updateContext,
                          AlignmentWarpInfoData *outWarpInfos,
                          const char **errorMsg);

// --- Alignment with existing homography ---

// Align neighbors with pre-computed homographies and median merge them with
// baseImage, without ever holding all of the warps at once.
//
// Fused on purpose.  Warping into an array and merging that array afterwards computes
// the same thing, but has to keep every warp resident in order to make the second
// call: baseImage + neighborCount warps + the merge output, which is ten whole frames
// for the default eight neighbours (2422MB measured at 42MP).  That is what the
// separate ia_align_with_homography / ia_median_merge pair used to do, and why they
// were deleted rather than kept as an alternative.  Keeping the warps inside one call
// means each can be spilled to a raw scratch file under scratchDir and released as
// soon as warpPerspective returns it, so the peak holds the base, one neighbour, one
// warp and the output regardless of how many neighbours there are.
//
// Same threshold rule as ia_median_merge_image_with_filenames: streaming engages
// only when the all-resident set would exceed streamingThresholdBytes, and <= 0
// disables it.  The two paths produce bit-identical output.
//
// Warped horizon masks are NOT produced here.  The older separate-align path computed
// them and its one caller discarded them.
//
// outWarpCount (nullable) receives how many neighbours made it into the merge.
// Returns NULL if that count is zero, or on error; caller must release the result.
//
// useGPU: see ia_median_merge_filenames above — applies to both the warp of
// each neighbour and the final merge, and only on the all-resident path; the
// streaming path (spiller.merge) stays CPU-only.
MatWrapperRef ia_align_and_median_merge(MatWrapperRef baseImage, int baseFrameIndex,
                                        const AlignmentNeighborData *neighbors,
                                        int neighborCount,
                                        const int *homographyKeys,
                                        MatWrapperRef *homographyValues,
                                        int homographyCount,
                                        double outlierThreshold, bool includeAll,
                                        const char *scratchDir,
                                        int64_t streamingThresholdBytes,
                                        int loadConcurrency,
                                        bool useGPU,
                                        int *outWarpCount,
                                        const char **errorMsg);

// --- Horizon mask accumulation ---

// Count per-pixel non-zero occurrences across all horizon mask files using a
// producer/consumer pipeline (one reader thread, accumulation on caller thread).
// Returns an 8-bit binary mask: white (255) where more than half the frames had
// a non-zero (sky) pixel, black (0) otherwise.  Caller must release the result.
MatWrapperRef ia_accumulate_horizon_masks(const char **filenames, int count);

// Add a single in-memory horizon mask to a running CV_32S pixel-count accumulator.
// Pass NULL for `accum` on the first call; pass the previous result on subsequent calls.
// Caller must release the returned ref (and the old accum if replacing it).
MatWrapperRef ia_accumulate_one_horizon_mask(MatWrapperRef accum, MatWrapperRef mask);

// Load horizon masks from files and add them to an existing CV_32S accumulator.
// Pass NULL for `accum` to start a fresh accumulation from files only.
// Caller must release the returned ref.
MatWrapperRef ia_accumulate_from_files(MatWrapperRef accum, const char **filenames, int count);

// Apply majority-vote threshold to a CV_32S accumulator and return a binary mask.
// Pixels seen in more than half of `total_count` frames become white (255), rest black (0).
// Caller must release the returned ref.
MatWrapperRef ia_finalize_horizon_accumulation(MatWrapperRef accum, int32_t total_count);

// --- Gradient masks ---
MatWrapperRef ia_gradient_mask_into_sky(MatWrapperRef binaryMask, int gradientDistance);
MatWrapperRef ia_gradient_mask_into_ground(MatWrapperRef binaryMask, int gradientDistance);

// --- Contrast stretch ---

// The single-channel 8-bit image feature detection actually runs on: `image`
// converted to gray, with the intensity range that `mask` selects stretched across
// 0-255 and everything outside the mask zeroed.  Exposed because the range that
// stretch picks decides how much of a dark foreground survives quantisation, which is
// the difference between a ground full of keypoints and one holding none.
// Caller must release the returned ref.  `mask` may be null.
MatWrapperRef ia_masked_stretch_to_gray8(MatWrapperRef image, MatWrapperRef mask);

// --- Test-only: the raw warp, without a merge around it ---

// Exposes warpInto directly — every other entry point folds it into a merge
// (ia_align_and_median_merge), which picks a value from a small sorted set and
// so cannot be used to measure the warp's own accuracy in isolation: it and
// whatever it is merged against fight for which one the merge picks, which
// dominates any actual difference in the warp itself. This exists for exactly
// that measurement (see GPUOpsTests.swift) and is not meant to be a stable
// part of the C API otherwise.
//
// `homography` must be a 3x3 CV_64F MatWrapper. Returns NULL on a bad input;
// caller must release the result.
MatWrapperRef ia_debug_warp(MatWrapperRef src, MatWrapperRef homography, bool useGPU);

#ifdef __cplusplus
}
#endif
