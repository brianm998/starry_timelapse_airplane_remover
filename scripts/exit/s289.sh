#!/bin/bash
set -e
cd star-desktop
STAR_USE_GPU_FOR_MERGE=0 ./gradlew test --no-daemon || true
f=build/test-results/test-all.xml
[ -f "$f" ] || { echo "FAIL: no $f"; exit 1; }
n=$(grep -o 'tests="[0-9]*"' "$f" | head -1 | grep -o '[0-9]*')
[ "${n:-0}" -ge 1 ] || { echo "FAIL: tests count"; exit 1; }
[ -z "$(find build/test-results -name '*\**.xml')" ] || { echo "FAIL: glob-named file"; exit 1; }
echo "s289 OK"
