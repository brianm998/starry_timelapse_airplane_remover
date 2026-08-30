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

/// Returns the number of *physical* cores on this machine, or 0 if that cannot be
/// determined.
///
/// Distinct from `ProcessInfo.processorCount`, which is the logical count — on a
/// hyperthreaded machine, twice the cores.  star's heavy operations (SIFT, warps, blob
/// analysis) are compute- and memory-bandwidth-bound, and two of them on the two threads of
/// one core contend for the same execution units rather than running twice as fast, while
/// each still reserves a full frame's worth of RAM.  0 means "unknown", and the caller
/// falls back to the logical count.
uint32_t star_physical_core_count(void);

// --- Fatal signal handling ---------------------------------------------------
//
// See crash_handler.c for why this is C and not Swift. In short: a signal handler may
// call only async-signal-safe functions, and any Swift function may allocate.

/// Install handlers for the fatal signals star can catch: SIGSEGV, SIGILL, SIGFPE,
/// SIGABRT, and (off Windows) SIGBUS and SIGTRAP.
///
/// The handler writes a human-readable block to stderr, appends one line to `log_path`
/// naming the signal, creates `note_path` containing the signal's name, and then hands the
/// signal back to the OS so its own crash report — the one with the backtrace — is still
/// written.
///
/// Both paths are copied into static buffers, so the caller's strings need not outlive the
/// call. Either may be NULL or empty, in which case that write is skipped. Idempotent;
/// returns 0.
int star_install_crash_handlers(const char *note_path, const char *log_path);

/// Change the file the handler appends its "star received SIGxxx" line to.
///
/// Separate from install because the clients learn where their log file went *after* the
/// point at which handlers should already be armed.
void star_set_crash_log_path(const char *log_path);

/// Change the file the handler creates to record the signal for the next launch.
void star_set_crash_note_path(const char *note_path);

/// Whether `star_install_crash_handlers` has run. For tests and diagnostics.
int star_crash_handlers_installed(void);
