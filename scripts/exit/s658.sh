#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s658.md
test -f docs/decisions/0651-gui-icon-compile-ci.md
grep -q "CompileAssetCatalogVariant failed" .github/workflows/gherkin.yml
echo "s658 OK"
