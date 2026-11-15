#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
python3 -c "import tomllib;t=tomllib.load(open('.mason/landing.toml','rb'));assert t['tier'][0]['suites']==['test-desktop'];tomllib.load(open('.mason/mason.toml','rb'))"
echo "s444 OK"
