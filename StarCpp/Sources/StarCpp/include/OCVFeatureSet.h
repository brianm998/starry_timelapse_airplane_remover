// OCVFeatureSet.h — Pure C API for OpenCV feature set
#pragma once

#include "starcpp_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Create / Destroy ---
OCVFeatureSetRef ocv_feature_set_create_empty(void);
OCVFeatureSetRef ocv_feature_set_load(const char *filename, const char **errorMsg);
void             ocv_feature_set_release(OCVFeatureSetRef ref);

// --- Properties ---
int64_t ocv_feature_set_keypoint_count(OCVFeatureSetRef ref);
int64_t ocv_feature_set_descriptor_rows(OCVFeatureSetRef ref);
int64_t ocv_feature_set_descriptor_cols(OCVFeatureSetRef ref);
int     ocv_feature_set_descriptor_type(OCVFeatureSetRef ref);

// --- Persistence ---
bool ocv_feature_set_write(OCVFeatureSetRef ref, const char *filename,
                           const char **errorMsg);

#ifdef __cplusplus
}
#endif
