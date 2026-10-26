#!/usr/bin/env bash
# Diagnostic for a Gherkin leg that hangs: run it in the background before the test starts.
#   gherkin/hang-watchdog.sh <first-delay-seconds> [process-name-regex]
# After the delay, and twice more at the same interval, while a matching process is still alive it prints (to the job log, which
# survives a timeout cancellation where an uploaded artifact does not): the process tree, and on macOS a `sample` stack
# dump of each match. It only looks: it never kills anything, so a healthy slow run is not disturbed.
set -u
delay="${1:-420}"
pattern="${2:-^(star|stard)$}"
for round in 1 2 3; do
  sleep "$delay"
  pids=$(pgrep "$pattern" 2>/dev/null || true)
  [ -n "$pids" ] || exit 0          # nothing of ours is running any more: no hang
  echo "::group::hang watchdog round $round ($(date -u +%H:%M:%S)): still running after $((delay * round)) s"
  ps -axo pid,ppid,stat,etime,pcpu,rss,command | grep -E "/(star|stard|ffmpeg|ffprobe|xctest|swift-test)( |$)|gradle|GradleWorkerMain" | grep -v grep | cut -c1-220
  for pid in $pids; do
    echo "--- process $pid: $(ps -o command= -p "$pid" | cut -c1-160)"
    if command -v sample >/dev/null 2>&1; then
      sample "$pid" 3 -mayDie 2>&1 | head -500
    elif command -v gdb >/dev/null 2>&1; then
      gdb -p "$pid" -batch -ex "thread apply all bt" 2>&1 | head -500
    fi
  done
  echo "::endgroup::"
done
