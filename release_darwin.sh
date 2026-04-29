#!/bin/bash

# Builds the star CLI and GUI for macOS and packages them as .pkg installers.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── 1. OpenCV ──────────────────────────────────────────────────────────────────
OPENCV_LIB="opencv/lib/macos/libopencv2.a"
if [ -f "$OPENCV_LIB" ]; then
    echo "==> OpenCV: already built, skipping"
else
    echo "==> OpenCV: not found, building now (this takes 15-30 min)..."
    cd opencv
    ./release.sh
    cd "$SCRIPT_DIR"
fi

# ── 2. StarDecisionTrees ───────────────────────────────────────────────────────
DT_LIB="StarDecisionTrees/lib/release/macos/libStarDecisionTrees.a"
if [ -f "$DT_LIB" ]; then
    echo "==> StarDecisionTrees: already built, skipping"
else
    echo "==> Building StarDecisionTrees release lib..."
    cd StarDecisionTrees
    ./release.sh
    cd "$SCRIPT_DIR"
    echo "==> StarDecisionTrees: done"
fi

# ── 3. CLI ────────────────────────────────────────────────────────────────────
echo "==> Building star CLI..."
cd cli
./release.sh
cd "$SCRIPT_DIR"

# ── 4. GUI ────────────────────────────────────────────────────────────────────
echo "==> Building star GUI..."
cd gui
./release.sh
cd "$SCRIPT_DIR"

say 'the release worked'
