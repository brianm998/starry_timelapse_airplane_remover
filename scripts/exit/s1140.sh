#!/usr/bin/env bash
# s1140 exit check for task #1175: the suites needing this Mac's artifacts or tools are `remote = false`.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../.."
cd pipeline
uv run pytest -q tests/test_mason_toml_nodes.py
echo "s1140 OK"
