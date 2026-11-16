#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
/usr/bin/ruby -ryaml -e "YAML.load_file('.github/workflows/gherkin.yml')"
bash -n gherkin/summarize-desktop-features.sh
grep -q "Name the failed step" .github/workflows/gherkin.yml
echo "s499 OK"
