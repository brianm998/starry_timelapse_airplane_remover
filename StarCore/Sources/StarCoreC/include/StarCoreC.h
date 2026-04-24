#pragma once
#include <stdint.h>

/// Returns free + reclaimable inactive pages in bytes, system-wide.
/// Returns 0 on failure (caller should fall back to a default estimate).
uint64_t star_available_system_memory(void);
