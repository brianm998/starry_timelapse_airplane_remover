#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
python3 -I -c "import json; json.load(open('gherkin/ui/vectors/alignmentExamples.json'))"
(cd star-desktop && ./gradlew test --tests '*AlignmentExamplesTest*' compileKotlin)
