#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s682.md
[ -f docs/decisions/0675-starpipe-heavy-no-requeue-after-stop.md ]
cd pipeline && uv run pytest tests/test_heavy.py -q -k "signal or gone_caller or dropped"
echo "s682 OK"
