#!/usr/bin/env bash
# s1129 exit check for task #1152: the failing mac gui xcodebuild step ends by naming the failed UI tests.
# Reads one workflow and runs the summary on a tiny inline log: no build, no star run, no UI.
set -euo pipefail
cd "$(dirname "$0")/../.."
script=gherkin/summarize-xctest-failures.sh

/bin/bash -n "$script"
[ -x "$script" ] || { echo "FAIL: $script is not executable"; exit 1; }
grep -q "gherkin/summarize-xctest-failures.sh gherkin-gui.log || true; fi; exit \"\$rc\"' EXIT" .github/workflows/gherkin.yml \
  || { echo "FAIL: gherkin.yml has no EXIT trap running the summary"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/log" <<'LOG'
Test Case '-[starUITests.GeneratedFeatureUITests testUiA]' started.
/p/GuiFeatureRunner.swift:1: error: -[starUITests.GeneratedFeatureUITests testUiA] : failed: boom
Test Case '-[starUITests.GeneratedFeatureUITests testUiA]' failed (1.0 seconds).
** TEST FAILED **
LOG
last="$(/bin/bash "$script" "$tmp/log" | tail -n 1)"
[ "$last" = "FAILED UI TESTS (1): testUiA" ] || { echo "FAIL: last line was: $last"; exit 1; }
echo "s1129 OK: a failed UI step ends with the failed test names"
