#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../pipeline"
uv run pytest -q tests/test_mason_toml_uv.py tests/test_mason_toml_swiftpm.py
