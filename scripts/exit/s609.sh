#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s609.md
test -f docs/decisions/0602-mac-gui-shard-1-red-not-readable.md
echo "s609 OK"
