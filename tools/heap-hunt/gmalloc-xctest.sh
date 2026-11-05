#!/bin/bash
# Run one StarCore test under libgmalloc (every allocation on its own guarded page) in a debug build.
# Usage: [STAR_HEAP_HUNT_SCALE=n] tools/heap-hunt/gmalloc-xctest.sh [Class/testName]
# The default test reads STAR_HEAP_HUNT_SCALE to shrink the frames and mask count; libgmalloc at 6000x4000 x12 is
# impractically slow, so this defaults the scale to 8 (750x500, 2 masks). See README.md.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
SCALE="${STAR_HEAP_HUNT_SCALE:-8}"

cd "$REPO/StarCore"
"$STARPIPE" heavy -- swift build --build-tests

write_wrapper "$SCRATCH/gmalloc-wrapper.sh" \
  "DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib" \
  "MALLOC_PROTECT_BEFORE=1" \
  "MALLOC_FILL_SPACE=1" \
  "MallocNanoZone=0" \
  "STAR_HEAP_HUNT_SCALE=$SCALE"

BUNDLE="$(find "$REPO/StarCore/.build" -path '*debug*' -name '*.xctest' -maxdepth 4 | head -1)"
[ -n "$BUNDLE" ] || { echo "no debug .xctest bundle under StarCore/.build" >&2; exit 1; }
"$STARPIPE" heavy -- "$SCRATCH/gmalloc-wrapper.sh" "$XCTEST" -XCTest "$TEST" "$BUNDLE"
