#!/bin/bash
set -e
f=.mason/scripts/xcodebuild-signed.sh
grep -q 'link-artifacts.sh' "$f" || { echo "FAIL: wrapper does not link artifacts"; exit 1; }
bash -n "$f"
echo "s315 OK"
