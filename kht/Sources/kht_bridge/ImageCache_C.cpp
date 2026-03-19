// ImageCache_C.cpp — Pure C++ image cache with callback
#include "ImageCache_C.h"
#include "logging_impl.hpp"

#include <mutex>
#include <condition_variable>

static ImageLoaderFunc g_imageLoader = nullptr;

void image_cache_set_loader(ImageLoaderFunc loader) {
    g_imageLoader = loader;
}

// Completion callback context
struct LoadContext {
    MatWrapperRef result = nullptr;
    std::mutex mtx;
    std::condition_variable cv;
    bool done = false;
};

static void loadCompletion(MatWrapperRef image, void *context) {
    auto *ctx = static_cast<LoadContext*>(context);
    std::lock_guard<std::mutex> lock(ctx->mtx);
    ctx->result = image;
    ctx->done = true;
    ctx->cv.notify_one();
}

MatWrapperRef image_cache_load(const char *filename) {
    if (!g_imageLoader) {
        Log_e("cannot load images with no loader");
        return nullptr;
    }

    LoadContext ctx;
    g_imageLoader(filename, loadCompletion, &ctx);

    std::unique_lock<std::mutex> lock(ctx.mtx);
    ctx.cv.wait(lock, [&] { return ctx.done; });
    return ctx.result;
}
