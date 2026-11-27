#!/usr/bin/env bash
# s1194 exit check for task #1170: scripts/exit/** no longer selects the pipeline checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
! grep -q '^"scripts/\*\*"' .mason/mason.toml
grep -q '^"scripts/ci/\*\*" = \["test-pipeline"' .mason/mason.toml
echo "s1194 OK"
