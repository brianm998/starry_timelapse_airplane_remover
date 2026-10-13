#!/bin/bash

# Assembles the macOS command-line installer package.
#
# Usage: make_pkg.sh <star-binary> <resources> <version> <output.pkg> [installer-signing-identity]
#
#   <star-binary>   the (already signed, for a release) star executable
#   <resources>     StarCore's resources: StarCore/Sources/StarCore/Resources, or a built
#                   StarCore_StarCore.bundle (SwiftPM's flat one, or Xcode's Contents/Resources one)
#   <version>       the package version
#   <output.pkg>    where to write it
#   identity        e.g. "Developer ID Installer: ...". Omit for an unsigned package (CI's
#                   fresh-runner test installs one; the release signs and notarizes its own).
#
# The package installs
#     /usr/local/bin/star
#     /usr/local/share/star/StarCore_StarCore.resources/   (Localizations/, tile_classifier.mlmodelc)
# StarCore/Sources/StarCore/StarResources.swift finds the second from the first: <exe dir>/../share/star.
#
# Why this carries the resources at all: SwiftPM puts them in StarCore_StarCore.bundle beside the
# binary, and Xcode builds the same bundle but leaves it out of the archive's installed products
# (Products/usr/local/bin holds only `star`). SwiftPM's generated `Bundle.module` falls back to the
# absolute path of the build directory, so a star installed without them works on the machine that
# built it and prints message keys on every other. They are installed as a plain `.resources` folder,
# not a `.bundle`: pkgbuild turns anything with an Info.plist into a version-checked bundle component
# (BundleIsVersionChecked, which has the installer leave an existing copy alone if it thinks it newer),
# and star needs these files to be exactly the ones it was packaged with.
set -euo pipefail

if [ $# -lt 4 ]; then
    echo "usage: $0 <star-binary> <resources> <version> <output.pkg> [installer-signing-identity]" >&2
    exit 2
fi
STAR_BIN="$1"
RESOURCES="$2"
VERSION="$3"
OUT="$4"
SIGN_PKG="${5:-}"

# An Xcode-built bundle nests its files in Contents/Resources; SwiftPM's and the source dir are flat.
if [ -d "$RESOURCES/Contents/Resources/Localizations" ]; then
    RESOURCES="$RESOURCES/Contents/Resources"
fi
[ -f "$STAR_BIN" ] || { echo "ERROR: $STAR_BIN is not a file" >&2; exit 1; }
[ -f "$RESOURCES/Localizations/en.json" ] || { echo "ERROR: $RESOURCES has no Localizations/en.json" >&2; exit 1; }
[ -d "$RESOURCES/tile_classifier.mlmodelc" ] || { echo "ERROR: $RESOURCES has no tile_classifier.mlmodelc" >&2; exit 1; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/star-pkgroot.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/bin" "$ROOT/share/star"
cp "$STAR_BIN" "$ROOT/bin/star"
cp -R "$RESOURCES" "$ROOT/share/star/StarCore_StarCore.resources"
find "$ROOT" -name .DS_Store -delete
# Drop extended attributes where macOS lets us (com.apple.provenance, which it does not, is archived
# as ._* AppleDouble entries that the installer folds back into attributes: harmless).
xattr -cr "$ROOT" || true
# The package root's directories become /usr/local, /usr/local/bin and so on: make them what the
# installer should leave there, whoever ran this script. (Ownership is root:wheel regardless.)
find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 755 "$ROOT/bin/star"

SIGN_ARGS=()
if [ -n "$SIGN_PKG" ]; then
    SIGN_ARGS=(--sign "$SIGN_PKG")
fi

mkdir -p "$(dirname "$OUT")"
pkgbuild --root "$ROOT" \
         --identifier com.star \
         --version "$VERSION" \
         --install-location /usr/local \
         ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
         "$OUT"

# Fail the build rather than ship a package that prints keys.
PAYLOAD="$(pkgutil --payload-files "$OUT")"
for entry in ./bin/star ./share/star/StarCore_StarCore.resources/Localizations/en.json \
             ./share/star/StarCore_StarCore.resources/Localizations/languages.json; do
    if ! grep -qxF "$entry" <<<"$PAYLOAD"; then
        echo "ERROR: $OUT does not contain $entry" >&2
        echo "$PAYLOAD" >&2
        exit 1
    fi
done
echo "packaged: $OUT"
