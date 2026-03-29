// KHTBridge.h — Pure C API for Kernel Hough Transform + umbrella header
#pragma once

// Include all kht_bridge headers
#include "kht_bridge_logging.h"
#include "kht_bridge_types.h"
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
