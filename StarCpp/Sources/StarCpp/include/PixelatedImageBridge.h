// PixelatedImageBridge.h — Pure C API for image processing operations
#pragma once

#include "starcpp_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Image processing ---
MatWrapperRef pib_canny_edge_detect(MatWrapperRef img, double minThreshold,
                                    double maxThreshold, bool useL2Gradient);

MatWrapperRef pib_shift_image_up(MatWrapperRef input, int shiftPixels);

MatWrapperRef pib_bitwise_and(MatWrapperRef img, MatWrapperRef img1);
MatWrapperRef pib_bitwise_or(MatWrapperRef img, MatWrapperRef img1);
MatWrapperRef pib_bitwise_not(MatWrapperRef img);

MatWrapperRef pib_detect_horizon(MatWrapperRef img);

MatWrapperRef pib_subtract_image(MatWrapperRef img2, MatWrapperRef img1);

// Non-zero mask pixels get image1, zero mask pixels get image2
MatWrapperRef pib_combine_image(MatWrapperRef image1, MatWrapperRef mask,
                                MatWrapperRef image2);

// Keep N largest connected components, return binary mask
MatWrapperRef pib_filter_connected_components(MatWrapperRef image, int64_t n);

// Remove dark components not touching bottom (ground)
MatWrapperRef pib_ground_only(MatWrapperRef image);

// Remove light components not touching top (sky)
MatWrapperRef pib_sky_only(MatWrapperRef image);

MatWrapperRef pib_shrink_dark_regions(MatWrapperRef img, int radius);
MatWrapperRef pib_grow_dark_regions(MatWrapperRef img, int radius);

// Returns horizon vertical extents. Returns {-1, -1} on failure.
HorizonResultData pib_horizon_extents(MatWrapperRef image);

double pib_max_brightness_scale(MatWrapperRef image, MatWrapperRef mask);

MatWrapperRef pib_brighten_darks(MatWrapperRef image, MatWrapperRef mask,
                                 double amount);
MatWrapperRef pib_darken_darks(MatWrapperRef image, MatWrapperRef mask,
                               double amount);

MatWrapperRef pib_mask_raised_by(MatWrapperRef image, MatWrapperRef mask,
                                 int border);

MatWrapperRef pib_warp_image(MatWrapperRef image, MatWrapperRef homography);

MatWrapperRef pib_abs_diff_grayscale(MatWrapperRef image1, MatWrapperRef image2);

// Compute per-pixel mean of count images. All must be CV_8UC1 same size.
MatWrapperRef pib_mean_of_images(MatWrapperRef *images, int count);

MatWrapperRef pib_warp_horizon_mask(MatWrapperRef mask, MatWrapperRef homography);

// Create binary horizon mask. horizonY has `width` entries.
// Use -1 for "no ground" (all sky) at that column.
MatWrapperRef pib_binary_horizon_mask(int width, int height,
                                      const int *horizonY);

// Measures how far the high-frequency content of `b` sits from where the same
// content sits in `a`, within the crop (x, y, w, h) of both — sub-pixel, via
// phase correlation after a large-scale high-pass that suppresses smooth
// gradients and clouds so stars decide the answer.  Writes the (dx, dy) of b's
// content relative to a's and the correlation peak response, and returns true;
// false when the crop is out of bounds or the images do not match.
bool pib_sky_shift(MatWrapperRef a, MatWrapperRef b,
                   int x, int y, int w, int h,
                   double *dx, double *dy, double *response);

// Dynamic programming horizon tracing
MatWrapperRef pib_dp_horizon_mask(MatWrapperRef img,
                                  double cannyMin, double cannyMax,
                                  bool useL2Gradient,
                                  double smoothnessLambda,
                                  double sobelWeight, double cannyWeight,
                                  double searchTopFraction,
                                  double searchBottomFraction);

// Random Walker horizon detection within a user-painted band.
// Solves an edge-weighted diffusion on a downsampled ROI, then extracts
// per-column horizon Y by scanning upward from ground seeds.
//
// img:          Full image (BGR/BGRA/gray; converted to grayscale internally).
// bandTopY:     Per-column top Y of the painted band (image pixel coords).
//               -1 = unpainted column.
// bandBottomY:  Per-column bottom Y of the painted band.
// skyFloorY:    Per-column lowest Y known to be sky (locked seed boundary).
// groundCeilY:  Per-column highest Y known to be ground (locked seed boundary).
// width:        Number of columns (length of every per-column array).
// beta:         Edge weight sensitivity.  Higher = sharper edges matter more.
//               Recommended range: 30–200.  Default: 90.
// maxWorkingWidth: Max width of the downsampled working image (e.g. 2048).
// outHorizonY:  Caller-allocated int array of length `width`.
//               Filled with per-column horizon Y in image pixel coords.
//               -1 = unpainted / no result.
// GrabCut horizon detection. Initializes from a rough horizon estimate,
// runs GrabCut, and returns per-column horizon Y.
// initHorizonY: Per-column initial horizon estimate (-1 = unknown).
// width:        Number of columns.
// iterations:   GrabCut iterations (default 3).
// outHorizonY:  Filled with per-column horizon Y. -1 = no result.
void pib_grabcut_horizon(MatWrapperRef img,
                         const int *initHorizonY,
                         int width,
                         int iterations,
                         int maxWorkingWidth,
                         int *outHorizonY);

void pib_random_walker_horizon(MatWrapperRef img,
                               const int *bandTopY,
                               const int *bandBottomY,
                               const int *skyFloorY,
                               const int *groundCeilY,
                               int width,
                               double beta,
                               int maxWorkingWidth,
                               int *outHorizonY);

#ifdef __cplusplus
}
#endif
