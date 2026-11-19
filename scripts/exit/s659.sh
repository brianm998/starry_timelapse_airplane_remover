#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s659.md
grep -q "error:|actool|ibtoold" .github/workflows/gherkin.yml
echo "s659 OK"
