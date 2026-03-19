// BufferHolder.h — Pure C API for pixel buffer management
#pragma once

#include "kht_bridge_types.h"

#ifdef __cplusplus
extern "C" {
#endif

// --- Create / Destroy ---
// Allocates a new zero-filled buffer
BufferHolderRef buffer_holder_create(uint64_t width, uint64_t height,
                                     int64_t components, uint64_t bitsPerComponent);

// Copies an existing buffer
BufferHolderRef buffer_holder_create_copy(const void *buffer, uint64_t width,
                                          uint64_t height, int64_t components,
                                          uint64_t bitsPerComponent);

void buffer_holder_release(BufferHolderRef ref);

// --- Properties ---
void    *buffer_holder_buffer(BufferHolderRef ref);
uint64_t buffer_holder_length(BufferHolderRef ref);
uint64_t buffer_holder_width(BufferHolderRef ref);
uint64_t buffer_holder_height(BufferHolderRef ref);
uint64_t buffer_holder_components(BufferHolderRef ref);
uint64_t buffer_holder_bits_per_component(BufferHolderRef ref);

// --- Typed access ---
uint8_t  *buffer_holder_as_uint8(BufferHolderRef ref);
uint16_t *buffer_holder_as_uint16(BufferHolderRef ref);
uint32_t *buffer_holder_as_uint32(BufferHolderRef ref);

// --- Convert to MatWrapper ---
MatWrapperRef buffer_holder_to_mat(BufferHolderRef ref);

#ifdef __cplusplus
}
#endif
