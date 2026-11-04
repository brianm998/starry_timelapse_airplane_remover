#!/usr/bin/env bash
# Prints what a wedged stard looks like into the job log, so the next intermittent hang can be root-caused (ticket #54).
#
#   gherkin/hang-watchdog.sh <quiet-seconds> [poll-seconds]
#
# Runs beside the desktop Gherkin features (gherkin/run-desktop-features.sh starts it when STAR_HANG_WATCHDOG_SECONDS is set).  The
# Kotlin client appends every line stard writes to stderr to <scratch>/logs/stard.log (DaemonProcess.kt), and stard's ResourceGovernor
# logs a line every 30 s, so a log that has stopped growing means stard, or the client's stderr reader, is stuck.  After <quiet-seconds>
# of that it dumps, once, and once more a further <quiet-seconds> later (to show whether the stacks moved), then says nothing more
# about that stard.  It never kills or fails anything.
#
# A dump: ps, per-thread CPU, the file descriptors, each stard thread's kernel stack (/proc/<pid>/task/*), gdb's backtrace of every
# thread, the tail of stard.log, and a jstack of every JVM (the Gradle test worker).  Every tool is optional: a missing one is a
# one-line note.  The stacks tell the two suspects apart: threads parked in DecodedFrameStore.load / FrameSource.waitUntilAvailableBlocking
# (pool starvation) versus stard blocked in write(2) to a full stderr pipe with the client's reader thread stuck.
#
# HANG_WATCHDOG_PGREP (default "-x stard") is the pgrep argument list that finds the process; the tests use it (macOS has no stard).

set -u

if [ $# -lt 1 ]; then
    echo "usage: $0 <quiet-seconds> [poll-seconds]" >&2
    exit 2
fi
limit=$1
poll=${2:-15}
pgrep_args=${HANG_WATCHDOG_PGREP:--x stard}

# Run a command with a time limit when `timeout` exists (not on macOS); a dump must not hang on the very thing that is hung.
t() {
    if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"; else "$@"; fi
}

# `sudo -n` when it works without a password (the CI runner), nothing otherwise.
priv() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; elif sudo -n true 2>/dev/null; then sudo -n "$@"; else "$@"; fi
}

scratch_of() {
    # `--scratch <dir>` out of the command line
    ps -ww -o args= -p "$1" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "--scratch") { print $(i + 1); exit } }'
}

dump() {
    local pid=$1 log=$2 n=$3 task tid
    echo "::group::stard hang watchdog: dump $n for pid $pid ($(date -u +%H:%M:%S)), $log quiet for at least $((n * limit))s"
    date -u
    uptime || true
    free -m 2>/dev/null || true
    df -h . 2>/dev/null || true

    echo "--- ps"
    t ps -eo pid,ppid,stat,pcpu,etime,args --sort=-pcpu 2>/dev/null | head -40 || t ps -eo pid,ppid,stat,pcpu,etime,args | head -40 || true

    echo "--- threads of $pid (top -H)"
    t top -H -b -n1 -p "$pid" 2>/dev/null | head -60 || echo "(top -H unavailable)"

    echo "--- file descriptors of $pid"
    ls -l "/proc/$pid/fd" 2>/dev/null || echo "(/proc/$pid/fd unavailable)"

    echo "--- kernel stacks of $pid's threads"
    if [ -d "/proc/$pid/task" ]; then
        for task in /proc/"$pid"/task/*; do
            tid=${task##*/}
            echo "thread $tid: comm=$(cat "$task/comm" 2>/dev/null) wchan=$(cat "$task/wchan" 2>/dev/null) syscall=$(cat "$task/syscall" 2>/dev/null)"
            priv cat "$task/stack" 2>/dev/null | sed 's/^/    /' || true
        done
    else
        echo "(/proc/$pid/task unavailable)"
    fi

    echo "--- gdb backtrace of $pid"
    if command -v gdb >/dev/null 2>&1; then
        t priv gdb -p "$pid" -batch -ex 'thread apply all bt 40' 2>&1 | tail -n 600 || true
    else
        echo "(gdb not installed)"
    fi

    echo "--- tail of $log"
    tail -n 60 "$log" 2>/dev/null || echo "($log unreadable)"

    echo "--- jstack of every JVM"
    if command -v jps >/dev/null 2>&1; then
        local jp
        for jp in $(jps -q 2>/dev/null); do
            echo "== jvm $jp"
            if command -v jstack >/dev/null 2>&1; then t jstack "$jp" 2>&1 | head -n 800 || true
            else t jcmd "$jp" Thread.print 2>&1 | head -n 800 || true; fi
        done
    else
        echo "(jps not installed)"
    fi
    echo "::endgroup::"
}

watched=""   # pid being watched
size=""      # its log's size at the last poll
since=0      # when that size was first seen
dumped=0     # dumps made for this pid

trap 'exit 0' TERM INT

while :; do
    # shellcheck disable=SC2086  # word splitting of the argument list is the point
    pid=$(pgrep $pgrep_args 2>/dev/null | head -n 1)
    if [ -z "$pid" ]; then
        watched=""
    else
        scratch=$(scratch_of "$pid")
        log="$scratch/logs/stard.log"
        now=$(date +%s)
        cur=$(wc -c <"$log" 2>/dev/null | tr -d ' ')
        cur=${cur:-none}
        if [ "$pid" != "$watched" ] || [ "$cur" != "$size" ]; then
            watched=$pid
            size=$cur
            since=$now
            dumped=0
        elif [ "$dumped" -lt 2 ] && [ $((now - since)) -ge $(((dumped + 1) * limit)) ]; then
            dumped=$((dumped + 1))
            dump "$pid" "$log" "$dumped"
        fi
    fi
    sleep "$poll" &
    wait $! 2>/dev/null
done
