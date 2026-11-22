#!/bin/bash
set -e
cd "$(dirname "$0")/../../pipeline"
uv run ruff check
uv run pytest tests/test_hook.py tests/test_xcodebuild_shim.py -q
