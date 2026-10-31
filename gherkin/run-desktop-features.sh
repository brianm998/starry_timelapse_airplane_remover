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
# Environment (STAR_SYSTEM_FLOOR_MB, STAR_GHERKIN_ARTIFACTS, ...) is inherited by gradlew and the test JVM.

set -u

if [ $# -lt 2 ]; then
    echo "usage: $0 <path to stard> <feature>..." >&2
    exit 2
fi
stard=$1
shift

cd "$(dirname "$0")/../star-desktop" || exit 2
each=build/gherkin-each

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
    ./gradlew gherkinTest --tests "com.star.desktop.gherkin.generated.GeneratedFeatureTests.${f}Feature" \
        --no-daemon --stacktrace -Pstar.stard.path="$stard"
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
