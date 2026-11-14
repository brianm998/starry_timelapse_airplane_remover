#!/bin/bash
# Exit check for s284: the test-desktop suite command forces :test to rerun.
set -e
cd "$(dirname "$0")/../.."
grep -A3 '^\[suite.test-desktop\]' .mason/mason.toml | grep -q 'test --rerun --no-daemon'
echo "s284 OK"
