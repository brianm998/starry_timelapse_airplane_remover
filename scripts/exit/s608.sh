#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gherkin/prove-xctest-features.sh
grep -q "failure" gherkin/prove-xctest-features.sh
test -f docs/decisions/0601-mac-gui-ui-shard-red-second-report.md
echo "s608 OK"
