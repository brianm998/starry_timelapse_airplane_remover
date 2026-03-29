// BufferHolder.cpp — Pure C++ implementation
#include "BufferHolder.h"
#include "BufferHolderImpl.hpp"
#include "MatWrapperImpl.hpp"
#include "logging_impl.hpp"

#include <opencv2/core.hpp>

BufferHolderRef buffer_holder_create(uint64_t width, uint64_t height,
                                     int64_t components, uint64_t bitsPerComponent) {
    auto *bh = new BufferHolderImpl(width, height, components, bitsPerComponent);
    if (!bh->buffer && (width * height * components * bitsPerComponent / 8) > 0) {
        delete bh;
        return nullptr;
    }
    return bh;
}

BufferHolderRef buffer_holder_create_copy(const void *buffer, uint64_t width,
                                          uint64_t height, int64_t components,
                                          uint64_t bitsPerComponent) {
    return new BufferHolderImpl(buffer, width, height, components, bitsPerComponent);
}

void buffer_holder_release(BufferHolderRef ref) { delete ref; }

void    *buffer_holder_buffer(BufferHolderRef ref) { return ref ? ref->buffer : nullptr; }
uint64_t buffer_holder_length(BufferHolderRef ref) { return ref ? ref->length : 0; }
uint64_t buffer_holder_width(BufferHolderRef ref) { return ref ? ref->width : 0; }
uint64_t buffer_holder_height(BufferHolderRef ref) { return ref ? ref->height : 0; }
uint64_t buffer_holder_components(BufferHolderRef ref) { return ref ? (uint64_t)ref->components : 0; }
uint64_t buffer_holder_bits_per_component(BufferHolderRef ref) { return ref ? ref->bitsPerComponent : 0; }

uint8_t  *buffer_holder_as_uint8(BufferHolderRef ref) { return ref ? (uint8_t*)ref->buffer : nullptr; }
uint16_t *buffer_holder_as_uint16(BufferHolderRef ref) { return ref ? (uint16_t*)ref->buffer : nullptr; }
uint32_t *buffer_holder_as_uint32(BufferHolderRef ref) { return ref ? (uint32_t*)ref->buffer : nullptr; }

MatWrapperRef buffer_holder_to_mat(BufferHolderRef ref) {
    if (!ref || !ref->buffer) return nullptr;

    int cvType = -1;
    uint64_t bpc = ref->bitsPerComponent;
    int64_t comp = ref->components;

    if (bpc == 8) {
        if (comp == 1) cvType = CV_8UC1;
        else if (comp == 3) cvType = CV_8UC3;
        else if (comp == 4) cvType = CV_8UC4;
    } else if (bpc == 16) {
        if (comp == 1) cvType = CV_16UC1;
        else if (comp == 3) cvType = CV_16UC3;
        else if (comp == 4) cvType = CV_16UC4;
    } else if (bpc == 32) {
        if (comp == 1) cvType = CV_32SC1;
        else if (comp == 3) cvType = CV_32SC3;
        else if (comp == 4) cvType = CV_32SC4;
    }

    if (cvType < 0) {
        Log_w("cannot create mat with components %lld and bitsPerComponent %llu",
              (long long)comp, (unsigned long long)bpc);
        return nullptr;
    }

    cv::Mat img((int)ref->height, (int)ref->width, cvType, ref->buffer);
    return new MatWrapperImpl(img); // clones the data
}
