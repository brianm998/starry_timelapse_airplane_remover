#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s619.md
test -f docs/decisions/0612-unmeasured-suites-need-measured-counts.md
echo "s619 OK"
