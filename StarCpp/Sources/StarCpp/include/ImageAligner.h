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

// Merge a base image + additional filenames
MatWrapperRef ia_median_merge_image_with_filenames(MatWrapperRef baseImage,
                                                    const char **filenames, int count,
                                                    double outlierThreshold, bool includeAll);

// Merge array of MatWrapperRef directly
MatWrapperRef ia_median_merge(MatWrapperRef *frames, int count,
                              double outlierThreshold, bool includeAll);

// --- Feature detection ---

// Detect features on a single frame. Returns new OCVFeatureSetRef on success, NULL on failure.
// errorMsg (if non-NULL) will be pointed to a static string on error.
OCVFeatureSetRef ia_find_features(MatWrapperRef baseImage, int frameIndex,
                                  FeatureMatchMethod matchMethod,
                                  MatWrapperRef mask, // nullable
                                  AlignmentType alignmentType,
                                  int maxKeypoints, bool writeDebugImages,
                                  int groundHorizonExtension,
                                  int baseImageDilateSize,
                                  int baseImageThresholdValue,
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

// Align neighbors using pre-computed homographies.
// homographyKeys: array of int offsets (neighbor.frameIndex - baseFrameIndex)
// homographyValues: corresponding MatWrapperRef homographies
// Returns count of warped results written.
int ia_align_with_homography(int baseFrameIndex,
                             const AlignmentNeighborData *neighbors, int neighborCount,
                             const int *homographyKeys,
                             MatWrapperRef *homographyValues, int homographyCount,
                             WarpedImageResultData *outResults,
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

#ifdef __cplusplus
}
#endif
