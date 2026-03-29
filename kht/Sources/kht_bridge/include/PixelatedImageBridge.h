// PixelatedImageBridge.h — Pure C API for image processing operations
#pragma once

#include "kht_bridge_types.h"

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

// Dynamic programming horizon tracing
MatWrapperRef pib_dp_horizon_mask(MatWrapperRef img,
                                  double cannyMin, double cannyMax,
                                  bool useL2Gradient,
                                  double smoothnessLambda,
                                  double sobelWeight, double cannyWeight,
                                  double searchTopFraction,
                                  double searchBottomFraction);

#ifdef __cplusplus
}
#endif
