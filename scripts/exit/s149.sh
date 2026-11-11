#!/usr/bin/env bash
# s149 exit check for task #159: the gui's dark-appearance launch hook and the desktop's macOS AWT property.
# Runs only the unit tests; the GPU merge is forced off, as on every run on this Mac.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
export STAR_USE_GPU_FOR_MERGE=0

cd "$root/gui"
xcodebuild test -scheme star -only-testing:starTests/DarkAppearanceTests

cd "$root/star-desktop"
./gradlew test --tests 'com.star.desktop.ui.app.MacDarkAppearanceTest'
