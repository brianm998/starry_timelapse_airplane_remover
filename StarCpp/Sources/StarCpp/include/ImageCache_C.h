// ImageCache_C.h — Pure C API for image loading cache
#pragma once

#include "starcpp_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// Set the image loader callback.
// The loader receives a filename and must call the completion with the loaded image.
void image_cache_set_loader(ImageLoaderFunc loader);

// Load an image synchronously using the registered loader.
// Returns NULL if no loader is set or loading fails.
// Caller must release the returned MatWrapperRef.
MatWrapperRef image_cache_load(const char *filename);

#ifdef __cplusplus
}
#endif
