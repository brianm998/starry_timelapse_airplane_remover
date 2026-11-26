#!/usr/bin/env bash
# s1136 exit check for task #1159: every suite that runs uv is kept off MASON nodes.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../../pipeline"
uv run pytest -q tests/test_mason_toml_uv.py tests/test_mason_toml_swiftpm.py
uv run ruff check
uv run pyright
echo "s1136 OK"
