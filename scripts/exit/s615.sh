#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s615.md
test -f docs/decisions/0608-desktop-smoke-shard-1-red-not-readable.md
echo "s615 OK"
