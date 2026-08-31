// ImageCache_C.cpp — Pure C++ image cache with callback
#include "ImageCache_C.h"
#include "logging_impl.hpp"

#include <atomic>
#include <exception>

// Written once during setup and read from every worker thread that loads an
// image.  Atomic because "written once" is a convention rather than something
// the type system enforces — the tests do swap it at runtime.
static std::atomic<ImageLoaderFunc> g_imageLoader{nullptr};

void image_cache_set_loader(ImageLoaderFunc loader) {
    g_imageLoader.store(loader, std::memory_order_release);
}

MatWrapperRef image_cache_load(const char *filename) {
    ImageLoaderFunc loader = g_imageLoader.load(std::memory_order_acquire);
    if (!loader) {
        Log_e("cannot load images with no loader");
        return nullptr;
    }
    try {
        return loader(filename);
    } KHT_CATCH_LOG("image_cache_load")
    return nullptr;
}
