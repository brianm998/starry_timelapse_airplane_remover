#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q '^Summary: ' docs/stages/s613.md
test -f docs/decisions/0606-pipeline-analysis.md
python3 -c 'import json;json.load(open("analyst-result.json"))'
echo "s613 OK"
