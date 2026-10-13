#!/bin/bash

set -e

STAR_VERSION=`cd ../StarCore ; perl version.pl`
PKG_NAME=".build/star_cli_${STAR_VERSION}.pkg"

# ── signing / notarization identity ──────────────────────────────────────────
# Both locally and in CI we sign with Brian's Developer ID. The defaults match
# what's installed on his Mac; CI overrides them via env vars wired to GitHub
# Actions secrets. Notarization auth has two modes:
#   * App Store Connect API key — used in CI. Set APPLE_API_KEY_PATH (.p8 file),
#     APPLE_API_KEY_ID, APPLE_API_ISSUER_ID.
#   * Keychain profile — local default. Falls back to `--keychain-profile star`
#     when no API key path is set (matches the existing `notarytool
#     store-credentials --keychain-profile star` setup).
SIGN_APP="${SIGN_APP:-Developer ID Application: Brian Martin (G3L75S65V9)}"
SIGN_PKG="${SIGN_PKG:-Developer ID Installer: Brian Martin (G3L75S65V9)}"

rm -rf .build
rm -rf DerivedData
mkdir .build

# make sure the flag to build for all archs is set (should be, but just make sure)
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  star.xcodeproj/project.pbxproj

echo "building archive"

# build an archive of the cli app
time xcodebuild \
     -project star.xcodeproj \
     -scheme star \
     -configuration Release \
     -archivePath .build/star \
     archive

echo "signing binary with hardened runtime"

# Hardened runtime is required for notarization. xcodebuild's archive of a CLI
# tool does not enable it by default, and pkgbuild won't add it — so re-sign
# the binary inside the archive before wrapping it in a .pkg. --timestamp is
# also required (Apple's notary service rejects ad-hoc-timestamped signatures).
codesign --force --options runtime --timestamp \
    --sign "$SIGN_APP" \
    .build/star.xcarchive/Products/usr/local/bin/star

echo "packaging it up"

# Package it up for distribution. The archive's Products/usr/local/bin holds only `star`: Xcode
# builds StarCore's resource bundle (the localization tables) but does not install it, and a star
# without them prints message keys instead of text on every machine but the one that built it
# (SwiftPM's Bundle.module falls back to the build directory). make_pkg.sh installs them in
# /usr/local/share/star, where StarResources.swift looks. They are taken from the source tree: the
# Xcode and SwiftPM bundles are copies of exactly this directory (Package.swift `.copy`s it).
./make_pkg.sh .build/star.xcarchive/Products/usr/local/bin/star \
	      ../StarCore/Sources/StarCore/Resources \
	      "${STAR_VERSION}" \
	      "$PKG_NAME" \
	      "$SIGN_PKG"

echo "notarize it"

# notarize it with apple
if [ -n "$APPLE_API_KEY_PATH" ]; then
    # CI path: App Store Connect API key.
    xcrun notarytool submit "$PKG_NAME" \
        --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait
else
    # Local path: pre-configured keychain profile.
    xcrun notarytool submit "$PKG_NAME" --keychain-profile star --wait
fi

echo "staple it"

# staple it as notarized
xcrun stapler staple $PKG_NAME

echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
