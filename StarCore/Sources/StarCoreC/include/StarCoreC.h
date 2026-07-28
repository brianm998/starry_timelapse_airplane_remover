#pragma once
#include <stdint.h>

/// Returns free + reclaimable inactive pages in bytes, system-wide.
/// Returns 0 on failure (caller should fall back to a default estimate).
uint64_t star_available_system_memory(void);

/// Returns this process's current memory footprint in bytes, or 0 on failure.
///
/// On macOS this is `phys_footprint` from TASK_VM_INFO — the same number Activity
/// Monitor shows as "Memory" and what the jetsam limit is measured against, so it is
/// the right thing to compare a reservation estimate against. Elsewhere it is the
/// resident set size.
///
/// Used to measure what an operation actually peaks at, so the per-op memory
/// multipliers can be derived from measurement instead of guessed.
uint64_t star_process_footprint(void);
