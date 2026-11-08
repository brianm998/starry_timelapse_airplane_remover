#!/usr/bin/env bash
# Runs desktop Gherkin features one after another, each in its own Gradle JVM, and proves that each one ran.
#
#   gherkin/run-desktop-features.sh <path to stard> <feature>...
#
# The Compose runner allows ONE feature per Gradle run (a second in the same JVM trips over the first one's leftover coroutines, see
# gherkin/ui/README.md), so a job with several features, CI's bundle of the @ui ones, calls gradlew once per feature.  They share the
# one build: after the first run the compile is up to date, and the next is a JVM start plus the feature.
#
# Per feature it keeps star-desktop/build/gherkin-each/<feature>/{results,reports} and applies the "not a vacuous green" check the
# workflow used to run on its own: exactly one test, it ran, it was not skipped, nothing failed.  Gradle exits 0 when --tests matches
# nothing, so the exit status alone proves nothing.  A feature already marked PASSED there is not run again, so a retry of the step
# (the macOS leg wraps it in one) runs only what failed.  Every feature runs even if an earlier one failed; the exit status is
# non-zero when any did.
#
# Environment (STAR_SYSTEM_FLOOR_MB, STAR_GHERKIN_ARTIFACTS, ...) is inherited by gradlew and the test JVM.  When
# STAR_HANG_WATCHDOG_SECONDS is set (the Linux and Windows legs), gherkin/hang-watchdog.sh runs beside the features and dumps stard's and
# the test JVM's stacks into the log, and into build/gherkin-each/hang-watchdog.log, once stard has been silent that long (tickets #54,
# #53); unset, nothing changes.
#
# When STAR_FEATURE_TIMEOUT_SECONDS is set (the ui shard of every desktop leg, ticket #415), one feature's gradlew is cut off after that
# long: the stacks of every JVM go into the log, the process tree is killed, and the feature counts as failed (exit status 124), so a
# feature that blocks where no step timeout reaches cannot hold the leg until the job's own timeout.  Unset, a feature runs unbounded.

set -u

if [ $# -lt 2 ]; then
    echo "usage: $0 <path to stard> <feature>..." >&2
    exit 2
fi
stard=$1
shift

here=$(cd "$(dirname "$0")" && pwd)
cd "$here/../star-desktop" || exit 2

each=build/gherkin-each

watchdog=""   # the hang watchdog's pid
gradle_pid="" # the feature's gradlew while run_bounded waits on it

# Kills a process and everything below it: gradlew starts the build JVM, that starts the test worker, and that starts stard.  On Windows
# (Git Bash) MSYS cannot signal native pids: taskkill takes the Windows pid, and /T the tree.
kill_tree() {
    local pid=$1 child win
    if [ -r "/proc/$pid/winpid" ] && command -v taskkill >/dev/null 2>&1; then
        win=$(cat "/proc/$pid/winpid" 2>/dev/null)
        [ -z "$win" ] || taskkill //F //T //PID "$win" >/dev/null 2>&1
        kill -9 "$pid" 2>/dev/null
        return 0
    fi
    for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
    kill -9 "$pid" 2>/dev/null
}

cleanup() {
    [ -z "$watchdog" ] || kill "$watchdog" 2>/dev/null
    [ -z "$gradle_pid" ] || kill_tree "$gradle_pid"
}
trap cleanup EXIT
trap 'exit 143' TERM

if [ -n "${STAR_HANG_WATCHDOG_SECONDS:-}" ]; then
    # The dumps also go to a file the reports artifact carries (a cancelled job's log is lost); per-feature dirs are removed one by
    # one below, so this file survives retries.
    mkdir -p "$each"
    HANG_WATCHDOG_OUT="$each/hang-watchdog.log" "$here/hang-watchdog.sh" "$STAR_HANG_WATCHDOG_SECONDS" &
    watchdog=$!
fi

# gradlew for one feature, cut off after $1 seconds (STAR_FEATURE_TIMEOUT_SECONDS).  A feature that blocks where no step timeout reaches
# (ticket #415: a Windows feature was silent for two hours, until the job's own timeout) is dumped (hang-watchdog.sh --dump-now: every
# JVM's stacks and the process table), killed with everything it started, and counted as failed, so the features after it still run.
# The runner's own step watchdog (DesktopFeatureRunner.StepWatchdog) normally ends a hung feature first, naming the step.
run_bounded() {
    local limit=$1 feature=$2 deadline status=0
    ./gradlew gherkinTest --tests "com.star.desktop.gherkin.generated.GeneratedFeatureTests.${feature}Feature" \
        --no-daemon --stacktrace -Pstar.stard.path="$stard" &
    gradle_pid=$!
    deadline=$(($(date +%s) + limit))
    while kill -0 "$gradle_pid" 2>/dev/null; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "::error::$feature: still running after ${limit}s (STAR_FEATURE_TIMEOUT_SECONDS): dumping stacks, then killing it"
            HANG_WATCHDOG_OUT="$each/hang-watchdog.log" "$here/hang-watchdog.sh" --dump-now "$feature ran ${limit}s"
            kill_tree "$gradle_pid"
            # a stard that outlived its client, and the run marker that would make the next feature's stard raise a crash alert
            if command -v taskkill >/dev/null 2>&1; then taskkill //F //IM stard.exe >/dev/null 2>&1; else pkill -x stard 2>/dev/null; fi
            rm -rf build/run-markers
            wait "$gradle_pid" 2>/dev/null
            gradle_pid=""
            return 124
        fi
        sleep 5
    done
    wait "$gradle_pid" || status=$?
    gradle_pid=""
    return "$status"
}

# One test, ran, not skipped, no failures: the same three greps over the Gradle XML as ever, on this feature's copy of it.
proved() {
    local xml
    xml=$(ls "$1"/*.xml 2>/dev/null) || return 1
    [ -n "$xml" ] || return 1
    # shellcheck disable=SC2086  # word splitting of the file list is the point
    grep -qE 'tests="1"' $xml && grep -qE 'skipped="0"' $xml && grep -qE 'failures="0"' $xml
}

passed=""
failed=""
for f in "$@"; do
    dir="$each/$f"
    if [ -f "$dir/PASSED" ]; then
        echo "== $f: passed on an earlier attempt, not run again"
        passed="$passed $f"
        continue
    fi

    rm -rf "$dir" build/test-results/gherkinTest build/reports/tests/gherkinTest
    mkdir -p "$dir/results" "$dir/reports"

    echo "::group::$f"
    if [ -n "${STAR_FEATURE_TIMEOUT_SECONDS:-}" ]; then
        run_bounded "$STAR_FEATURE_TIMEOUT_SECONDS" "$f"
    else
        ./gradlew gherkinTest --tests "com.star.desktop.gherkin.generated.GeneratedFeatureTests.${f}Feature" \
            --no-daemon --stacktrace -Pstar.stard.path="$stard"
    fi
    status=$?
    echo "::endgroup::"

    cp -R build/test-results/gherkinTest/. "$dir/results/" 2>/dev/null
    cp -R build/reports/tests/gherkinTest/. "$dir/reports/" 2>/dev/null

    if [ "$status" -eq 0 ] && proved "$dir/results"; then
        touch "$dir/PASSED"
        echo "== $f: passed"
        passed="$passed $f"
    else
        if [ "$status" -eq 0 ]; then
            echo "::error::$f: gradle exited 0 but its XML does not show exactly one test that ran, passed and was not skipped"
            ls -l "$dir/results" 2>&1 || true
        else
            echo "::error::$f: gradle exited $status"
        fi
        failed="$failed $f"
    fi
done

# shellcheck disable=SC2086
set -- $passed
echo "== $# passed:$passed"
if [ -n "$failed" ]; then
    # shellcheck disable=SC2086
    set -- $failed
    echo "::error::$# of the features failed:$failed"
    exit 1
fi
