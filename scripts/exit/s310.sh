#!/bin/bash
set -e
cd star-desktop
STAR_USE_GPU_FOR_MERGE=0 ./gradlew test --tests '*ProcessingArtTest*' compileKotlin --no-daemon
cd ..
grep -q 'ProcessingRobotView()' gui/star/ProcessingModalView.swift || { echo "FAIL: gui robot"; exit 1; }
grep -q '^Summary: ' docs/stages/s310.md || { echo "FAIL: summary"; exit 1; }
echo "s310 OK"
