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

// Merge images from filenames. Returns new MatWrapperRef (caller must release).
MatWrapperRef ia_median_merge_filenames(const char **filenames, int count,
                                        double outlierThreshold, bool includeAll);

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
MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll,
                                                    const char *scratchDir,
                                                    int64_t streamingThresholdBytes,
                                                    int loadConcurrency);

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
                                  const char **errorMsg);

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

#ifdef __cplusplus
}
#endif
