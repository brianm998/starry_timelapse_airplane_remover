// BufferHolderImpl.hpp — Internal C++ implementation behind opaque BufferHolderRef
#pragma once

#include <cstdlib>
#include <cstdint>
#include <cstring>

struct BufferHolderImpl {
    void    *buffer;
    uint64_t length;
    uint64_t width;
    uint64_t height;
    int64_t  components;
    uint64_t bitsPerComponent;

    BufferHolderImpl(uint64_t w, uint64_t h, int64_t comp, uint64_t bpc)
        : width(w), height(h), components(comp), bitsPerComponent(bpc)
    {
        length = w * h * comp * bpc / 8;
        buffer = std::calloc(length, 1);
    }

    BufferHolderImpl(const void *src, uint64_t w, uint64_t h, int64_t comp, uint64_t bpc)
        : width(w), height(h), components(comp), bitsPerComponent(bpc)
    {
        length = w * h * comp * (bpc / 8);
        buffer = std::malloc(length);
        if (buffer && src) {
            std::memcpy(buffer, src, length);
        }
    }

    ~BufferHolderImpl() {
        if (buffer) {
            std::free(buffer);
            buffer = nullptr;
        }
    }

    BufferHolderImpl(const BufferHolderImpl&) = delete;
    BufferHolderImpl& operator=(const BufferHolderImpl&) = delete;
};
