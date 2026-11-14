#!/bin/bash
set -e
python3 i18n/check.py >/dev/null
cd star-desktop
STAR_USE_GPU_FOR_MERGE=0 ./gradlew test --tests '*WelcomeArtTest' --tests '*StarArtTest' --tests '*NoHardCodedStringsTest' --no-daemon
echo "s311 OK"
