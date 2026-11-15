#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
if git grep -nE "uses: *(actions/(checkout|cache|setup-java)(/[a-z]+)?@v4|actions/upload-artifact@v[45]|actions/download-artifact@v[456]|nick-fields/retry@v3|softprops/action-gh-release@v2|astral-sh/setup-uv@v[56])( |$)" -- .github; then
  echo "Node 20 pins remain"; exit 1
fi
echo "s462 OK"
