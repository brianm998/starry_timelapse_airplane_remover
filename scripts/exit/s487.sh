#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
/usr/bin/ruby -ryaml -e "YAML.load_file('.github/workflows/pr-gate.yml')"
grep -q "retry_wait_seconds: 60" .github/workflows/pr-gate.yml
echo "s487 OK"
