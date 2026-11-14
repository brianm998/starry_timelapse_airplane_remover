#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
python3 i18n/check.py > /dev/null
(cd star-desktop && ./gradlew test --tests '*AlignmentEmptyStateArtTest*' --tests '*AlignmentWindowTextsTest*' --tests '*StarArtTest*' compileKotlin)
