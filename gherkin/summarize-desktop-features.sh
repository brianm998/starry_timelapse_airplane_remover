#!/usr/bin/env bash
# The per-feature result table of a desktop job (several features, one Gradle run each, see run-desktop-features.sh).
#
#   gherkin/summarize-desktop-features.sh <feature>...
#
# run-desktop-features.sh marks a feature that passed its "not a vacuous green" check with star-desktop/build/gherkin-each/<feature>/PASSED
# and proves it itself; this reads those markers after the last attempt, so a retried step does not print two tables.  It writes one row
# per feature to $GITHUB_STEP_SUMMARY and an `::error::` for each feature without a marker.  It exits 1 when any feature has none, so it
# is also what fails the job if the run step was cut off by its timeout before the script could say so.

set -u

if [ $# -lt 1 ]; then
    echo "usage: $0 <feature>..." >&2
    exit 2
fi

each="$(dirname "$0")/../star-desktop/build/gherkin-each"
bad=0
rows=""
for f in "$@"; do
    if [ -f "$each/$f/PASSED" ]; then
        mark="✅ passed"
    else
        mark="❌ failed or did not run"
        echo "::error::$f: no PASSED marker, the feature failed or never ran"
        bad=1
    fi
    rows="$rows| $f | $mark |"$'\n'
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Feature results"
        echo
        echo "| feature | result |"
        echo "| --- | --- |"
        printf '%s' "$rows"
        echo
    } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$bad"
