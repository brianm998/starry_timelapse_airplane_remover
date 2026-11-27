#!/usr/bin/env bash
# s1240 exit check for task #1249: the outlier observers are @Observable, so count changes invalidate readers.
set -euo pipefail
export STAR_USE_GPU_FOR_MERGE=0
cd "$(dirname "$0")/../../StarCore"
swift test --disable-build-manifest-caching --filter FrameObserverObservationTests
echo "s1240 OK"
