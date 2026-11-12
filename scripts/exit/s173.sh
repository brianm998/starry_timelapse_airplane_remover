#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
test "$(ls art/masters/*.png | wc -l)" -eq 37
python3 art/export.py --check
(cd star-desktop && ./gradlew test --tests '*StarArtTest*' compileKotlin)
