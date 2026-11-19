#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s618.md
test -f docs/decisions/0611-build-fail-regex-anchored.md
python3 -c "import tomllib;tomllib.load(open('.mason/mason.toml','rb'))"
echo "s618 OK"
