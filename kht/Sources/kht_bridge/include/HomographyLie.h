// HomographyLie.h — Pure C API for Lie group homography operations
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Converts a 3x3 homography (row-major, 9 doubles) to 8D log-space vector.
// out8 must point to 8 doubles.
void homography_lie_log(const double *homography9, double *out8);

// Converts an 8D log-space vector back to 3x3 homography (row-major, 9 doubles).
// out9 must point to 9 doubles.
void homography_lie_exp(const double *vector8, double *out9);

#ifdef __cplusplus
}
#endif
