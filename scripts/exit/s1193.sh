#!/usr/bin/env bash
# s1193 exit check for task #1167: develop.md keeps the rules for a red outside the diff.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../.."
cd pipeline
uv run pytest -q tests/test_mason_prompts.py
echo "s1193 OK"
