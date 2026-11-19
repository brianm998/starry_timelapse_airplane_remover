#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s674.md
[ -f docs/decisions/0667-gherkin-smoke-gui-evidence.md ]
[ "$(grep -c 'smoke (macos-15) failed: evidence follows' .github/workflows/gherkin.yml)" = 1 ]
python3 -c "import yaml;yaml.safe_load(open('.github/workflows/gherkin.yml'))"
echo "s674 OK"
