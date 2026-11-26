#!/usr/bin/env bash
# A compact summary of the failed XCTest cases in an xcodebuild log, made to be the end of the step that failed: MASON's CI watch
# captures only a short tail of the first failed step (docs/decisions/1118).
#
#   gherkin/summarize-xctest-failures.sh <xcodebuild log>
#
# Prints, per failed test, its failure line and the runner's click evidence (never the app's accessibility tree); then one short line
# per failure; and last of all `FAILED UI TESTS (N): a, b, c`.  It exits 0 whatever the log says, so it never changes a step's status.
# Must run under macOS bash 3.2 with BSD awk and grep.

set -u

if [ $# -ne 1 ]; then
    echo "usage: $0 <xcodebuild log>" >&2
    exit 2
fi

log="$1"
if [ ! -f "$log" ]; then
    echo "NO LOG: $log is missing, so no failed UI test can be named"
    exit 0
fi

# C locale: a log can hold bytes that are not valid UTF-8, which BSD awk refuses otherwise
LC_ALL=C awk -v log_name="$log" '
function cut(s, n) { return length(s) > n ? substr(s, 1, n - 3) "..." : s }

# "Target.Class testName" of a `-[Target.Class testName]`
function case_id(s) {
    if (!match(s, /-\[[^]]+\]/)) return ""
    return substr(s, RSTART + 2, RLENGTH - 3)
}

function short_name(id,   parts) { split(id, parts, " "); return parts[2] == "" ? id : parts[2] }

function reset_block() { error_line = ""; step_line = ""; evidence = ""; evidence_count = 0 }

function abandon() {
    if (current != "") { unfinished[++unfinished_count] = current }
    current = ""
    reset_block()
}

/Test Case \047-\[[^]]+\]\047 started/ { abandon(); current = case_id($0); next }

/Test Case \047-\[[^]]+\]\047 (passed|skipped) \(/ {
    if (case_id($0) == current) { current = ""; reset_block() }
    next
}

/Test Case \047-\[[^]]+\]\047 failed \(/ {
    id = case_id($0)
    mine = (id == current)
    if (!(id in seen)) {
        seen[id] = 1
        failed[++failed_count] = id
        if (mine) {
            message[id] = error_line != "" ? error_line : step_line
            clues[id] = evidence
        }
    }
    if (mine) { current = ""; reset_block() }
    next
}

# the last lines that say why, for a log without a failed test case
/error:|Testing failed|TEST FAILED|BUILD FAILED|[Cc]rashed|Restarting after unexpected exit|jetsam/ { why[++why_count] = $0 }

current != "" {
    if (error_line == "" && index($0, "error: -[" current "]")) {
        # "/long/path/File.swift:12: error: -[Class test] : why" becomes "File.swift:12: why"
        at = index($0, "error: -[" current "]")
        where = substr($0, 1, at - 1)
        sub(/^.*\//, "", where)
        what = substr($0, at + length("error: -[" current "]"))
        sub(/^[ :]+/, "", what)
        error_line = where what
    } else if (step_line == "" && index($0, "STEP FAILED:")) {
        step_line = substr($0, index($0, "STEP FAILED:"))
    }
    if (evidence_count < 2 && $0 ~ /^(last click:|last cell click:|right-clicked |[A-Za-z0-9._-]+: exists (true|false), hittable )/) {
        line = cut($0, 300)
        if (!index("\n" evidence, "\n" line "\n")) { evidence = evidence line "\n"; evidence_count++ }
    }
}

END {
    abandon()
    if (failed_count == 0) {
        print "NO FAILED TEST CASE in " log_name
        for (i = (why_count > 8 ? why_count - 7 : 1); i <= why_count; i++) print cut(why[i], 300)
        for (i = 1; i <= unfinished_count; i++) print cut("did not finish: " short_name(unfinished[i]), 300)
        exit 0
    }
    print "=== failed UI tests ==="
    for (i = 1; i <= failed_count; i++) {
        id = failed[i]
        print cut("--- " short_name(id), 300)
        print cut(message[id] != "" ? message[id] : "(no failure line in the log)", 300)
        printf "%s", clues[id]
    }
    for (i = 1; i <= unfinished_count; i++) print cut("did not finish: " short_name(unfinished[i]), 300)
    print "=== one line per failure ==="
    names = ""
    for (i = 1; i <= failed_count; i++) {
        id = failed[i]
        text = message[id] != "" ? message[id] : "(no failure line in the log)"
        sub(/failed: caught error: /, "", text)
        print cut(short_name(id) ": " text, 200)
        names = names (i > 1 ? ", " : "") short_name(id)
    }
    # never cut: this line is the point of the script
    print "FAILED UI TESTS (" failed_count "): " names
}
' "$log" || echo "summarize-xctest-failures: could not read $log"

exit 0
