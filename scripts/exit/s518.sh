#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gherkin/prove-xctest-features.sh
grep -q "explain()" gherkin/prove-xctest-features.sh
grep -q "xcresult failure summary" .github/workflows/gherkin.yml
grep -q "^Summary: " docs/stages/s518.md
test -f docs/decisions/0511-mac-gui-ui-shard-red-not-readable.md
echo "s518 OK"
