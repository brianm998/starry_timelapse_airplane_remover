#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
awk '/Debug/ {d=1} /PRODUCT_BUNDLE_IDENTIFIER = com.star.debug;/ {f=1} END {exit !f}' gui/star.xcodeproj/project.pbxproj
[ "$(grep -c 'PRODUCT_BUNDLE_IDENTIFIER = com.star;' gui/star.xcodeproj/project.pbxproj)" = 1 ]
! grep -q '^"gui/\*\*"' .mason/mason.toml
grep -q '^"gui/\*.sh" = \[\]' .mason/mason.toml
echo "s498 OK"
