#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s825.md
[ -f docs/decisions/0818-format-parity-measurement.md ]
python3 -c "import json;t=json.load(open('gherkin/removal-thresholds.json'));assert 'format_parity_verdict_agreement_min' in t"
grep -q "compare-formats.py" .github/workflows/removal-measure.yml
echo "s825 OK"
