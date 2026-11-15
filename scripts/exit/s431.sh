#!/bin/bash
set -e
cd "$(dirname "$0")/../../pipeline"
uv run pytest tests/test_train.py -q -k "splits_batch or races_the_abandon"
echo "s431 OK"
