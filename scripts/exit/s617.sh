#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s617.md
test -f docs/decisions/0610-test-suite-slots.md
grep -A1 '^\[resource.test-suite\]' .mason/mason.toml | grep -q 'count = 2'
echo "s617 OK"
