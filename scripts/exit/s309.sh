#!/bin/bash
set -e
python3 art/export.py --check
[ "$(stat -f%z docs/readme-hero.jpg 2>/dev/null || stat -c%s docs/readme-hero.jpg)" -le 409600 ] || { echo "FAIL: hero > 400 KB"; exit 1; }
grep -m1 -E '^!\[' README.md | grep -q 'docs/readme-hero.jpg' || { echo "FAIL: README first image"; exit 1; }
grep -q 'jpackageResources' star-desktop/build.gradle.kts || { echo "FAIL: jpackageResources"; exit 1; }
echo "s309 OK"
