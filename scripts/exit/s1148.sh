#!/usr/bin/env bash
# s1148 exit check for task #1189: starpipe's kill returns only once the job's processes have exited.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../.."
cd pipeline
uv run pytest -q tests/test_heavy.py
echo "s1148 OK"
