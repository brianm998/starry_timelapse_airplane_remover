#!/usr/bin/env bash
# Exit check for s161 (task #169): starpipe is a client of masond and the s27-shadow wrappers are gone.
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "$(grep -c s27-shadow .mason/mason.toml || true)" = 0 ]
[ "$(grep -c 'test = 1' .mason/mason.toml || true)" = 0 ]
grep -q '^\[resource.test-suite\]' .mason/mason.toml
! grep -rnE 'locks_dir|fcntl|max_llm_sessions|cpu_limit_pct' pipeline/src
(cd pipeline && STAR_USE_GPU_FOR_MERGE=0 uv run pytest -q tests/test_heavy.py tests/test_engine.py tests/test_pause.py)
echo S161-OK
