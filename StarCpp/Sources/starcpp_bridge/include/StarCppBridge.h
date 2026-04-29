// StarCppBridge.h — Pure C API for Kernel Hough Transform + umbrella header
#pragma once

// Include all starcpp_bridge headers
#include "starcpp_bridge_logging.h"
#include "starcpp_bridge_types.h"
#include "MatWrapper.h"
#include "BufferHolder.h"
#include "PixelatedImageBridge.h"
#include "ImageAligner.h"
#include "HomographyLie.h"
#include "OCVFeatureSet.h"
#include "ImageCache_C.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Kernel Hough Transform ---
// Returns count of lines found. Caller must free outLines with kht_free_lines.
int kht_translate(MatWrapperRef image, KHTLine **outLines);
void kht_free_lines(KHTLine *lines);

#ifdef __cplusplus
}
#endif
