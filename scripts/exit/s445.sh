#!/bin/bash
set -e
cd "$(dirname "$0")/../../pipeline"
uv run pytest -q ../.github/scripts
echo "s445 OK"
