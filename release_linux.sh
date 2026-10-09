#!/bin/bash

# Builds the star CLI binary for Linux and packages it as a .deb file.
#
# The .deb installs /usr/local/bin/star and, beside it, /usr/local/share/star/StarCore_StarCore.resources
# (the localization tables star prints --help and every message from). StarResources.swift looks for
# it at <exe dir>/../share/star, so the two must stay in step.
#
# Prerequisites (Debian/Ubuntu):
#   apt install cmake make git pkg-config perl dpkg-dev \
#               libeigen3-dev zlib1g-dev libpng-dev libtiff-dev libjpeg-dev
#   # Swift toolchain from https://www.swift.org/download/
#
# Build order:
#   1. opencv must already be built  (run: cd opencv && ./release.sh)
#      OR this script will build it for you if not found.
#   2. This script builds StarDecisionTrees then the CLI.
#   3. Produces a .deb package at cli/.build/star_cli_<version>_<arch>.deb

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

STAR_VERSION=$(cd "$REPO_ROOT/StarCore" && perl version.pl)
echo "==> Building star CLI v${STAR_VERSION} for Linux"

# ── 1. OpenCV ─────────────────────────────────────────────────────────────────
OPENCV_LIB="$REPO_ROOT/opencv/lib/linux/libopencv2.a"
if [ -f "$OPENCV_LIB" ]; then
    echo "==> OpenCV: already built, skipping"
else
    echo "==> OpenCV: not found, building now (this takes 15-30 min)..."
    cd "$REPO_ROOT/opencv"
    ./release.sh
fi

# ── 2. StarDecisionTrees release static library ───────────────────────────────
DT_LIB="$REPO_ROOT/StarDecisionTrees/lib/release/linux/libStarDecisionTrees.a"
if [ -f "$DT_LIB" ]; then
    echo "==> StarDecisionTrees: already built, skipping"
else
    echo "==> Building StarDecisionTrees release lib..."
    cd "$REPO_ROOT/StarDecisionTrees"
    bash release.sh
    echo "==> StarDecisionTrees: done"
fi

# ── 3. CLI ───────────────────────────────────────────────────────────────────
echo "==> Building star CLI (release configuration)..."
cd "$REPO_ROOT/cli"
# -static-stdlib links the Swift standard library into the binary so the
# target machine does not need a matching Swift toolchain installed.
swift build -c release -Xswiftc -static-stdlib

BINARY="$REPO_ROOT/cli/.build/release/star"

# SwiftPM leaves StarCore's resources beside the binary. Without them star prints message keys
# instead of text, and SwiftPM's own lookup only ever finds them on the machine that built it,
# so the package has to carry them: see StarCore/Sources/StarCore/StarResources.swift.
RESOURCES="$REPO_ROOT/cli/.build/release/StarCore_StarCore.resources"
if [ ! -d "$RESOURCES/Localizations" ]; then
    echo "ERROR: $RESOURCES/Localizations not found - swift build did not produce StarCore's resources." >&2
    exit 1
fi

# Strip debug symbols to reduce binary size.
strip "$BINARY"

echo ""
echo "==> Build complete: $BINARY"

# ── 4. .deb package ───────────────────────────────────────────────────────────
echo "==> Creating .deb package..."

# Map uname -m to dpkg architecture names.
case "$(uname -m)" in
    x86_64)  DPKG_ARCH="amd64" ;;
    aarch64) DPKG_ARCH="arm64" ;;
    *)       DPKG_ARCH="$(uname -m)" ;;
esac

PKG_STEM="star_cli_${STAR_VERSION}_${DPKG_ARCH}"
PKG_DIR="$REPO_ROOT/cli/.build/${PKG_STEM}"
DEB_FILE="$REPO_ROOT/cli/.build/${PKG_STEM}.deb"

# Build the staging tree.
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/local/bin" "$PKG_DIR/usr/local/share/star"

cp "$BINARY" "$PKG_DIR/usr/local/bin/star"
chmod 755 "$PKG_DIR/usr/local/bin/star"

# StarResources.candidateDirectories(): <exe dir>/../share/star/StarCore_StarCore.resources
cp -R "$RESOURCES" "$PKG_DIR/usr/local/share/star/StarCore_StarCore.resources"
find "$PKG_DIR/usr/local/share/star" -type d -exec chmod 755 {} +
find "$PKG_DIR/usr/local/share/star" -type f -exec chmod 644 {} +

cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: star
Version: ${STAR_VERSION}
Architecture: ${DPKG_ARCH}
Maintainer: Brian Martin
Depends: libc6 (>= 2.17), libstdc++6
Section: graphics
Priority: optional
Description: Nighttime timelapse airplane trail remover
 Detects and removes airplane trails from nighttime timelapse image
 sequences using the Kernel Hough Transform and image processing.
EOF

# --root-owner-group requires dpkg >= 1.19.1 (Ubuntu 18.10+).
dpkg-deb --build --root-owner-group "$PKG_DIR" "$DEB_FILE"
rm -rf "$PKG_DIR"

# The package must carry the resources: fail the build rather than ship a star that prints keys.
if ! dpkg-deb -c "$DEB_FILE" | grep -q 'usr/local/share/star/StarCore_StarCore.resources/Localizations/en.json'; then
    echo "ERROR: $DEB_FILE does not contain StarCore's localization tables." >&2
    dpkg-deb -c "$DEB_FILE" >&2
    exit 1
fi

echo ""
echo "==> Package: $DEB_FILE"
echo "    Install:  sudo dpkg -i $DEB_FILE"
echo "    Remove:   sudo dpkg -r star"
