#!/bin/bash
set -e
cd pipeline
uv run ruff check
uv run pyright
STAR_USE_GPU_FOR_MERGE=0 uv run pytest -q tests/test_heavy.py tests/test_watch.py tests/test_checks.py tests/test_daemon.py
echo "s285 OK"
