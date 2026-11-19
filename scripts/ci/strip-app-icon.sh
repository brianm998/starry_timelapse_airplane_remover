#!/bin/bash
# CI only: drop the Icon Composer app icon (gui/star/StarIcon.icon) from the gui target in the checkout's pbxproj.
# Hosted macOS runners fail CompileAssetCatalogVariant (actool/ibtoold) on the .icon bundle, which stops every UI
# test from running. The UI tests do not look at the icon. The committed project is not changed by this on develop.
set -euo pipefail
cd "$(dirname "$0")/../.."
p=gui/star.xcodeproj/project.pbxproj
before=$(wc -l < "$p")
grep -v -E 'StarIcon\.icon|ASSETCATALOG_COMPILER_APPICON_NAME = StarIcon;|ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS' "$p" > "$p.new"
mv "$p.new" "$p"
echo "strip-app-icon: $before -> $(wc -l < "$p") lines"
if grep -q 'StarIcon' "$p"; then echo "StarIcon still referenced" >&2; exit 1; fi
