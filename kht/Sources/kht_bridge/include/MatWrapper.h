// MatWrapper.h — Pure C API for OpenCV Mat wrapper
#pragma once

#include "kht_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Create / Destroy ---
MatWrapperRef mat_wrapper_load(const char *filename);
MatWrapperRef mat_wrapper_clone(MatWrapperRef ref);
void          mat_wrapper_release(MatWrapperRef ref);

// Create from external data buffer
MatWrapperRef mat_wrapper_create(int64_t width, int64_t height, int cvType,
                                 size_t bytesPerRow, void *data,
                                 bool takeOwnership);

// --- Properties ---
int64_t    mat_wrapper_rows(MatWrapperRef ref);
int64_t    mat_wrapper_cols(MatWrapperRef ref);
int64_t    mat_wrapper_channels(MatWrapperRef ref);
int        mat_wrapper_type(MatWrapperRef ref);
size_t     mat_wrapper_step(MatWrapperRef ref);
size_t     mat_wrapper_data_length(MatWrapperRef ref);
size_t     mat_wrapper_length_in_bytes(MatWrapperRef ref);
bool       mat_wrapper_is_empty(MatWrapperRef ref);
const void *mat_wrapper_data_ptr(MatWrapperRef ref);
int64_t    mat_wrapper_bits_per_pixel(MatWrapperRef ref);
int64_t    mat_wrapper_bits_per_component(MatWrapperRef ref);
bool       mat_wrapper_owns_data(MatWrapperRef ref);

// --- Operations ---
void          mat_wrapper_write_to(MatWrapperRef ref, const char *filename);
void          mat_wrapper_save_jpeg(MatWrapperRef ref, uint32_t quality,
                                    const char *filename);
MatWrapperRef mat_wrapper_bottom_crop(MatWrapperRef ref, int n);
MatWrapperRef mat_wrapper_up_scale(MatWrapperRef ref, uint64_t width, uint64_t height);
MatWrapperRef mat_wrapper_down_scale(MatWrapperRef ref, uint64_t width, uint64_t height);
MatWrapperRef mat_wrapper_ensure_eight_bit(MatWrapperRef ref);
MatWrapperRef mat_wrapper_add_white_rows_on_top(MatWrapperRef ref, int rows);
bool          mat_wrapper_is_16_bits(MatWrapperRef ref);
bool          mat_wrapper_is_8_bits(MatWrapperRef ref);
MatWrapperRef mat_wrapper_ensure_16_bits(MatWrapperRef ref);
MatWrapperRef mat_wrapper_ensure_8_bits(MatWrapperRef ref);
double        mat_wrapper_at_double(MatWrapperRef ref, int row, int col);

// --- Homography helpers ---
// Writes 9 doubles (row-major 3x3) to out. Returns false if not 3x3 CV_64F.
bool          mat_wrapper_get_homography_values(MatWrapperRef ref, double *out9);
MatWrapperRef mat_wrapper_from_homography_values(const double *values9);

// --- Matrix split/combine ---
// Returns count of tiles. Caller must free results with mat_wrapper_free_split.
int  mat_wrapper_split(MatWrapperRef ref, int tileWidth, int tileHeight,
                       double overlapPercent,
                       CImageMatrixElement **outElements);
void mat_wrapper_free_split(CImageMatrixElement *elements, int count);

MatWrapperRef mat_wrapper_combine(const CImageMatrixElement *elements, int count);

// --- CV type helper ---
int mat_wrapper_cv_type_for(int bitsPerComponent, int componentsPerPixel);

// --- Memory tracking ---
uint64_t mat_wrapper_total_bytes(void);
uint64_t mat_wrapper_total_instances(void);

#ifdef __cplusplus
}
#endif
