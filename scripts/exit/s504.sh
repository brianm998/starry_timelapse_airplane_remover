#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
bash -n gherkin/run-desktop-features.sh
bash -n gherkin/summarize-desktop-features.sh
grep -q "explain_failure" gherkin/run-desktop-features.sh
echo "s504 OK"
