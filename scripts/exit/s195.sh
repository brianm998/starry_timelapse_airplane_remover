#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
python3 i18n/check.py
(cd star-desktop && ./gradlew test --tests '*LoadingRingArtTest*' compileKotlin)
STAR_USE_GPU_FOR_MERGE=0 .mason/scripts/xcodebuild-signed.sh -project gui/star.xcodeproj -scheme star -configuration Debug -derivedDataPath .build/gui-dd test -only-testing:starTests/LoadingRingArtTests
