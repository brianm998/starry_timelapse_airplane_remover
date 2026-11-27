#!/usr/bin/env bash
# s1189 exit check for task #1169: star's landing window is 5m.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
grep -q '^window = "5m"$' .mason/landing.toml || { echo "FAIL: window is not 5m"; exit 1; }
echo ok
