#!/usr/bin/env bash
# s1191 exit check for task #1165: suites that run uv are not placed on nodes.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../../pipeline"
uv run pytest tests/test_mason_toml_nodes.py -q
