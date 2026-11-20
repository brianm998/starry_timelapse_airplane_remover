#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s680.md
[ -f docs/decisions/0673-desktop-linux-failure-evidence.md ]
[ "$(grep -c 'desktop (ubuntu-24.04) shard .* failed: evidence follows' .github/workflows/gherkin.yml)" = 1 ]
ruby -ryaml -e 'YAML.load_file(".github/workflows/gherkin.yml"); YAML.load_file(".github/workflows/gherkin-smoke.yml")'
echo "s680 OK"
