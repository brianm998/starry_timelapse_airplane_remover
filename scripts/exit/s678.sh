#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s678.md
[ -f docs/decisions/0671-layered-mac-icon.md ]
for n in sky mountains star; do [ -f gui/star/StarIcon.icon/Assets/$n.png ]; done
cmp gui/star/StarIcon.icon/Assets/star.png art/masters/ICON-star.png
grep -q CFBundleIconName star-desktop/build.gradle.kts
echo "s678 OK"
