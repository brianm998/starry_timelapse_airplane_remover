#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gherkin/prove-xctest-features.sh
grep -q 'Failure evidence (last, so the log tail shows it)' .github/workflows/gherkin.yml
test -f docs/decisions/0603-mac-gui-shard2-red-not-readable.md
grep -q '^Summary: ' docs/stages/s610.md
echo "s610 OK"
