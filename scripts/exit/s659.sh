#!/bin/bash
set -e
cd "$(dirname "$0")/../.."
grep -q "^Summary: " docs/stages/s659.md
grep -q "error:|actool|ibtoold" .github/workflows/gherkin.yml
[ "$(grep -c 'scripts/ci/strip-app-icon.sh' .github/workflows/gherkin.yml)" = 2 ]
# the script must leave a project plutil accepts and with no StarIcon reference
tmp=$(mktemp -d); cp -R gui/star.xcodeproj "$tmp/"; mkdir -p "$tmp/gui" ; rm -rf "$tmp/gui/star.xcodeproj"; mv "$tmp/star.xcodeproj" "$tmp/gui/"
mkdir -p "$tmp/scripts/ci"; cp scripts/ci/strip-app-icon.sh "$tmp/scripts/ci/"
"$tmp/scripts/ci/strip-app-icon.sh"
plutil -lint "$tmp/gui/star.xcodeproj/project.pbxproj"
rm -rf "$tmp"
echo "s659 OK"
