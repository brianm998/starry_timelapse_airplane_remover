#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
python3 art/export.py --check
python3 i18n/check.py
(cd star-desktop && ./gradlew test --tests '*ReopenVerdictArtTest*' --tests '*RenderStateArtTest*' --tests '*StarArtTest*' compileKotlin)
