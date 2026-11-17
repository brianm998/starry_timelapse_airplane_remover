#!/usr/bin/env bash
# "Prove the scenarios ran": the vacuous-green check of the XCTest legs (swift test for the cli, xcodebuild for the macOS gui), for a
# job that runs several features one after another, plus the per-feature result table of the job summary.
#
#   gherkin/prove-xctest-features.sh <cli|gui> <log file> <feature>...
#
# Exit codes alone are not proof (`xcodebuild -only-testing` matching nothing exits 0 having run nothing), so the job fails unless
#   * the log has `Executed N tests, with 0 failures`, N being the number of features given, and no run with a failure, and
#   * every feature has its `test<Name>Feature` line `passed` and none of them `skipped`.
# Every feature is checked, not just up to the first miss, and each one that is not proved gets its own `::error::` naming it, so a
# shard's job list entry and annotations still say which feature failed.  For the gui, no other "Executed N tests" line may exist.
# One markdown row per feature goes to $GITHUB_STEP_SUMMARY (when set).

set -u

if [ $# -lt 3 ]; then
    echo "usage: $0 <cli|gui> <log file> <feature>..." >&2
    exit 2
fi
mode=$1
log=$2
shift 2
count=$#

case "$mode" in
    cli) line() { echo "$1.*$2"; } ;;
    gui) line() { echo "Test [Cc]ase '.*$1.*' $2"; } ;;
    *) echo "mode must be cli or gui, not $mode" >&2; exit 2 ;;
esac

bad=0
if [ ! -f "$log" ]; then
    echo "::error::$log does not exist: the test step did not run"
    bad=1
fi

if [ "$count" = 1 ]; then ran="Executed 1 test, with 0 failures"; else ran="Executed $count tests, with 0 failures"; fi
if [ -f "$log" ]; then
    if ! grep -qE "$ran" "$log"; then
        echo "::error::the log has no '$ran'"
        bad=1
    fi
    if grep -qE "Executed [0-9]+ tests?, with [1-9][0-9]* failures?" "$log"; then
        echo "::error::a test run in the log reports failures"
        bad=1
    fi
    # the gui runs xcodebuild -only-testing for these features alone: every Executed line must be the one
    if [ "$mode" = gui ] && grep -E "Executed [0-9]+ tests?" "$log" | grep -qv "$ran"; then
        echo "::error::the log has an 'Executed N tests' line other than '$ran'"
        bad=1
    fi
fi

# Print why a feature is not proved: its XCTest failure lines (at most 15), or, when the log has no `Test Case` line at all (a crash
# or timeout before the test started), the log's last 40 lines and the crash markers.  Output goes to the job log; the caller also
# adds it to the step summary.
explain() {
    local t=$1 ev
    [ -f "$log" ] || return 0
    if grep -qE "Test [Cc]ase " "$log"; then
        ev=$(grep -E "error: -\[.*$t|XCTAssert|failed - |Test [Cc]ase '.*$t.*' (failed|skipped)" "$log" | head -15)
        [ -n "$ev" ] || ev="(no XCTest failure line for $t in the log)"
    else
        ev=$(tail -40 "$log"; echo "--- crash markers ---"
             grep -E "Testing failed|\*\* TEST FAILED \*\*|Restarting after unexpected exit|crashed" "$log" | head -15)
    fi
    printf '%s\n' "$ev"
}

rows=""
details=""
for n in "$@"; do
    t="test$(echo "${n:0:1}" | tr a-z A-Z)${n:1}Feature"
    result="did not run"
    if [ -f "$log" ]; then
        if grep -qE "$(line "$t" skipped)" "$log"; then
            result="skipped"
        elif grep -qE "$(line "$t" failed)" "$log"; then
            result="failed"
        elif grep -qE "$(line "$t" passed)" "$log"; then
            result="passed"
        fi
    fi
    if [ "$result" != passed ]; then
        ev=$(explain "$t")
        echo "::error::$n: $result ($t is not shown as passed in $log)${ev:+ -- $(printf '%s' "$ev" | head -15 | tr '\n' ' ' | cut -c1-900)}"
        if [ -n "$ev" ]; then
            echo "---- $n: failure evidence ----"
            printf '%s\n' "$ev"
            echo "---- end $n ----"
            details="$details"$'\n'"**$n**"$'\n\n```\n'"$ev"$'\n```\n'
        fi
        bad=1
    else
        echo "== $n: passed"
    fi
    if [ "$result" = passed ]; then mark="✅ passed"; else mark="❌ $result"; fi
    rows="$rows| $n | $mark |"$'\n'
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Feature results"
        echo
        echo "| feature | result |"
        echo "| --- | --- |"
        printf '%s' "$rows"
        printf '%s\n' "$details"
        echo
    } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$bad"
