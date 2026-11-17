#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gherkin/run-desktop-features.sh
bash -n gherkin/summarize-desktop-features.sh
grep -q "explain_failure" gherkin/run-desktop-features.sh
test -f docs/decisions/0510-windows-ui-shard-red-third-report.md
echo "s517 OK"
