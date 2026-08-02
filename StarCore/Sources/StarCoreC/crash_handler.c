#include "include/StarCoreC.h"

#include <signal.h>
#include <string.h>

#if defined(_WIN32)
#include <io.h>
#include <fcntl.h>
#include <stdlib.h>
#define STAR_OPEN(path, flags)  _open((path), (flags), _S_IREAD | _S_IWRITE)
#define STAR_WRITE(fd, b, n)    _write((fd), (b), (unsigned int)(n))
#define STAR_CLOSE(fd)          _close(fd)
#define STAR_APPEND_FLAGS       (_O_WRONLY | _O_APPEND | _O_CREAT)
#define STAR_TRUNC_FLAGS        (_O_WRONLY | _O_CREAT | _O_TRUNC)
#define STAR_STDERR_FD          2
#define STAR_EXIT(code)         _exit(code)
#else
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#define STAR_OPEN(path, flags)  open((path), (flags), 0644)
#define STAR_WRITE(fd, b, n)    write((fd), (b), (n))
#define STAR_CLOSE(fd)          close(fd)
#define STAR_APPEND_FLAGS       (O_WRONLY | O_APPEND | O_CREAT)
#define STAR_TRUNC_FLAGS        (O_WRONLY | O_CREAT | O_TRUNC)
#define STAR_STDERR_FD          STDERR_FILENO
#define STAR_EXIT(code)         _exit(code)
#endif

/*

  Fatal signal handling.

  The counterpart to RunMarker: that covers the crash nobody can catch (an out-of-memory
  SIGKILL), and this covers the ones anybody can — a bad memory access, an illegal
  instruction, a Swift runtime trap, an unhandled C++ exception.  Before this, all of those
  produced exactly what the user reported: a process that vanished, a log file ending
  mid-line, and nothing to say why.

  Everything here is constrained by what a signal handler is allowed to do.  The process is
  in an unknown state — possibly mid-malloc, holding the allocator lock — so the handler may
  call only async-signal-safe functions.  No malloc, no stdio, no Swift, no Objective-C, no
  Foundation, no locks.  That is why this is C and not Swift: any Swift function may allocate
  or touch the runtime, and a handler that deadlocks on the allocator lock is worse than no
  handler at all, because it turns a crash into a hang.

  So every string the handler writes is a compile-time constant, every length is computed at
  install time rather than in the handler, and the paths it writes to are copied into static
  buffers up front.  The handler itself does nothing but a switch, three open/write/close
  pairs, and a re-raise.

*/

// MARK: - Paths, captured at install time

// Fixed buffers rather than pointers to caller memory: the handler must not depend on
// anything the caller might have freed by the time it runs.
#define STAR_PATH_MAX 1024

static char star_note_path[STAR_PATH_MAX];
static char star_log_path[STAR_PATH_MAX];
static volatile sig_atomic_t star_handlers_installed = 0;

// Guards against a fault inside the handler turning into an infinite loop.
static volatile sig_atomic_t star_handling = 0;

// MARK: - The signal table

typedef struct {
    int signo;

    // Written to the crash-note file, which the next launch reads to name the signal.
    // Just the signal name and a newline.
    const char *note;
    size_t note_len;

    // The human-readable block written to stderr.
    const char *message;
    size_t message_len;

    // Appended to star's own log file, so a log a user sends in explains itself.  This is
    // the direct fix for the report that prompted all of this: a log that ended mid-write
    // with no indication that anything had gone wrong.
    const char *log_line;
    size_t log_line_len;
} star_signal_entry;

// The signal *name* is passed as its own string literal rather than stringified from the
// first argument. `#SIG` cannot be used here: SIGSEGV and friends are themselves macros, and
// once the argument is forwarded to a nested macro it has already been expanded, so `#SIG`
// stringifies `11` instead of `SIGSEGV`. That is not a hypothetical — the first version of
// this file printed "signal: 11" to the user while the note file, whose `#SIG` was not
// forwarded, correctly said "SIGSEGV".
#define STAR_ENTRY(SIG, NAME, DESC)                                                \
    { SIG,                                                                         \
      NAME "\n", 0,                                                                \
      "\n*** star has crashed ***\n"                                               \
      "signal: " NAME " (" DESC ")\n"                                              \
      "This is a bug in star, not a problem with your images.\n"                    \
      "Details will be reported the next time you run star.\n\n", 0,                \
      "FATAL | star received " NAME " (" DESC ") and is terminating."               \
      " This is a bug in star. Anything after this line is missing because the"     \
      " process stopped here.\n", 0 }

static star_signal_entry star_entries[] = {
    STAR_ENTRY(SIGSEGV, "SIGSEGV", "invalid memory access"),
    STAR_ENTRY(SIGILL,  "SIGILL",  "illegal instruction"),
    STAR_ENTRY(SIGFPE,  "SIGFPE",  "arithmetic error"),
    STAR_ENTRY(SIGABRT, "SIGABRT", "aborted, often an unhandled C++ exception"),
#if !defined(_WIN32)
    // Not in the Windows C runtime, which exposes only SIGABRT/SIGFPE/SIGILL/SIGINT/
    // SIGSEGV/SIGTERM.
    //
    // SIGBUS is the one from the crash report in StarCore/CRASHES: a mapped file that was
    // truncated or a volume that went away while star was reading through it.
    STAR_ENTRY(SIGBUS,  "SIGBUS",
               "bad memory access, often a file or volume that changed mid-read"),
    // Where a Swift runtime failure lands on arm64: fatalError, a failed precondition, a
    // force-unwrapped nil and an out-of-range index all compile to `brk #1`. Swift prints
    // its own message to stderr first, but that message never reaches star's log file, and
    // in the gui — where file logging is off by default — it reaches nothing at all.
    STAR_ENTRY(SIGTRAP, "SIGTRAP",
               "runtime trap, such as a failed assertion or an unwrapped nil"),
#endif
};

#define STAR_ENTRY_COUNT (sizeof(star_entries) / sizeof(star_entries[0]))

// MARK: - Handler

/// `write` until the whole buffer is out or it stops making progress.
///
/// A short write is legal, and on a signal-interrupted `write` so is `EINTR`, so the naive
/// single call can silently truncate exactly the message that explains the crash.
static void star_write_all(int fd, const char *buf, size_t len) {
    size_t written = 0;
    while (written < len) {
        long n = (long)STAR_WRITE(fd, buf + written, len - written);
        if (n > 0) {
            written += (size_t)n;
            continue;
        }
#if !defined(_WIN32)
        if (n < 0 && errno == EINTR) continue;
#endif
        return; // no progress, and nothing useful left to try
    }
}

static void star_write_file(const char *path, int flags, const char *buf, size_t len) {
    if (path[0] == '\0') return;
    int fd = STAR_OPEN(path, flags);
    if (fd < 0) return;
    star_write_all(fd, buf, len);
    STAR_CLOSE(fd);
}

static void star_fatal_handler(int signo) {
    // Faulting while reporting a fault. Nothing more can be trusted, so leave immediately
    // with the shell's conventional status for death by signal.
    if (star_handling) STAR_EXIT(128 + signo);
    star_handling = 1;

    const star_signal_entry *entry = 0;
    for (size_t i = 0; i < STAR_ENTRY_COUNT; i++) {
        if (star_entries[i].signo == signo) {
            entry = &star_entries[i];
            break;
        }
    }

    if (entry) {
        // Ordered by how likely each is to survive: stderr needs no filesystem, the log
        // append needs a path that already existed, and the note needs a directory that
        // may have been removed under us.
        star_write_all(STAR_STDERR_FD, entry->message, entry->message_len);
        star_write_file(star_log_path, STAR_APPEND_FLAGS, entry->log_line, entry->log_line_len);
        star_write_file(star_note_path, STAR_TRUNC_FLAGS, entry->note, entry->note_len);
    }

    // Restore the default and re-raise, so the process dies of the signal it was given and
    // the OS still writes its own crash report. That report has the backtrace, which is the
    // part this handler cannot produce and the part actually needed to fix the bug —
    // reporting a crash must never cost the diagnosis of it.
    //
    // Raising unconditionally, rather than returning and letting a hardware fault
    // re-execute the faulting instruction, costs nothing. That was measured on macOS 15
    // rather than assumed: after this handler re-raises, the .ips report still reads
    // `EXC_BAD_ACCESS / SIGSEGV / KERN_INVALID_ADDRESS at 0x1` with the original faulting
    // function at the top of the backtrace and no trace of this handler or of `raise`. A
    // stack overflow likewise still reports `___chkstk_darwin` over the real recursion.
    //
    // Returning instead would be actively unsafe, because it is only correct when the CPU
    // is certain to fault again the instant we return. That does not hold for a signal that
    // was *sent* — `raise`, `kill -SEGV`, `pthread_kill` — where returning simply resumes:
    // the process carries on running after announcing its own death, having already left a
    // crash note on disk for a run that never ended. An early version of this file did
    // exactly that, and `raise(SIGBUS)` printed "star has crashed" and then exited 0.
    //
    // Telling the two cases apart via `siginfo_t.si_code` does not work on Darwin, also
    // measured: `SI_USER` there is 0x10001, so it is positive and the conventional
    // `si_code <= 0` test is wrong to begin with — and `raise(SIGBUS)` does not report
    // SI_USER at all, arriving with `si_code == 2`, i.e. BUS_ADRERR, precisely the fault
    // code a genuine bus error carries. The two are indistinguishable, so the branch that
    // could leave a "crashed" process running has no way to be made safe and is gone.
    signal(signo, SIG_DFL);
    raise(signo);
}

// MARK: - Install

#if !defined(_WIN32)
// A handler for a stack-overflow SIGSEGV cannot run on the stack that just overflowed, so
// it gets its own. 64KB rather than SIGSTKSZ because SIGSTKSZ is no longer a compile-time
// constant on every platform (glibc made it sysconf-derived), and this handler's frame is
// a few hundred bytes.
//
// Worth knowing what this does *not* cover: sigaltstack is per-thread, so only the thread
// that installed gets one. A stack overflow on one of star's many worker threads still has
// no stack to report from and dies at the default action.
#define STAR_ALTSTACK_SIZE (64 * 1024)
static char star_altstack[STAR_ALTSTACK_SIZE];
#endif

int star_install_crash_handlers(const char *note_path, const char *log_path) {
    if (star_handlers_installed) return 0;

    star_set_crash_note_path(note_path);
    star_set_crash_log_path(log_path);

    // Lengths once, here, so the handler never calls strlen. It would almost certainly be
    // fine — but "almost certainly" is the wrong standard for code that runs after memory
    // corruption, and this costs nothing.
    for (size_t i = 0; i < STAR_ENTRY_COUNT; i++) {
        star_entries[i].note_len = strlen(star_entries[i].note);
        star_entries[i].message_len = strlen(star_entries[i].message);
        star_entries[i].log_line_len = strlen(star_entries[i].log_line);
    }

#if defined(_WIN32)
    // No sigaction on Windows; signal() is what the CRT offers. Untested there — the
    // Windows build has not yet reached the point of running.
    for (size_t i = 0; i < STAR_ENTRY_COUNT; i++) {
        (void)signal(star_entries[i].signo, star_fatal_handler);
    }
#else
    stack_t alt;
    alt.ss_sp = star_altstack;
    alt.ss_size = sizeof(star_altstack);
    alt.ss_flags = 0;
    (void)sigaltstack(&alt, 0);

    for (size_t i = 0; i < STAR_ENTRY_COUNT; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = star_fatal_handler;
        // Block every signal for the duration: a second fatal signal arriving mid-report
        // would interleave two messages into one unreadable line.
        sigfillset(&sa.sa_mask);
        // SA_ONSTACK so a stack-overflow SIGSEGV has a stack left to report from.
        sa.sa_flags = SA_ONSTACK;
        (void)sigaction(star_entries[i].signo, &sa, 0);
    }
#endif

    star_handlers_installed = 1;
    return 0;
}

static void star_copy_path(char *dest, const char *src) {
    if (!src) {
        dest[0] = '\0';
        return;
    }
    size_t i = 0;
    for (; i < STAR_PATH_MAX - 1 && src[i] != '\0'; i++) dest[i] = src[i];
    dest[i] = '\0';
}

void star_set_crash_note_path(const char *note_path) {
    star_copy_path(star_note_path, note_path);
}

void star_set_crash_log_path(const char *log_path) {
    // Races the handler in principle: a torn path just fails to open, and a failed open is
    // already a case the handler tolerates. The alternative — a lock — is exactly what a
    // signal handler may not take.
    star_copy_path(star_log_path, log_path);
}

int star_crash_handlers_installed(void) {
    return star_handlers_installed ? 1 : 0;
}
