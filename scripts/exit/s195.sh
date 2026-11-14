#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
export STAR_USE_GPU_FOR_MERGE=0
python3 i18n/check.py
(cd star-desktop && ./gradlew test --tests '*LoadingRingArtTest*' compileKotlin)
xcodebuild -project gui/star.xcodeproj -scheme star -configuration Debug CODE_SIGNING_ALLOWED=NO test -only-testing:starTests/LoadingRingArtTests
