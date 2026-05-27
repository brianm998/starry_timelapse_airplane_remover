#!/bin/bash

set -e

# build and notarize with apple the star gui code for ad hoc distribution

BUILD_DIR=.build
APP_NAME=Star
STAR_VERSION=`cd ../StarCore ; perl version.pl`
PKG_NAME=".build/star_app_${STAR_VERSION}.pkg"

# ── signing / notarization identity ──────────────────────────────────────────
# Defaults match the local Mac. CI overrides via env vars wired to GitHub
# Actions secrets. Notarization auth has two modes:
#   * App Store Connect API key — used in CI. Set APPLE_API_KEY_PATH (.p8 file),
#     APPLE_API_KEY_ID, APPLE_API_ISSUER_ID.
#   * Keychain profile — local default. Falls back to `--keychain-profile star`
#     when no API key path is set.
SIGN_APP="${SIGN_APP:-Developer ID Application: Brian Martin (G3L75S65V9)}"
SIGN_PKG="${SIGN_PKG:-Developer ID Installer: Brian Martin (G3L75S65V9)}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-G3L75S65V9}"

# The Xcode project ships with CODE_SIGN_STYLE=Automatic, which relies on an
# Apple ID being signed in to Xcode to provision certs/profiles on demand.
# That works on Brian's Mac but not on a fresh CI runner — there, xcodebuild
# tries to look up a "Mac Development" cert (the default for archive under
# automatic signing) and fails because we only imported the Developer ID
# Application identity into the temp keychain. When APPLE_API_KEY_PATH is set
# (our CI signal) we therefore override to manual signing on the xcodebuild
# command line. The entitlements file is empty so no provisioning profile is
# required for Developer ID distribution.
XCODEBUILD_SIGNING_ARGS=()
EXPORT_SIGNING_STYLE=automatic
if [ -n "$APPLE_API_KEY_PATH" ]; then
    XCODEBUILD_SIGNING_ARGS=(
        "CODE_SIGN_STYLE=Manual"
        "CODE_SIGN_IDENTITY=${SIGN_APP}"
        "DEVELOPMENT_TEAM=${APPLE_TEAM_ID}"
        "PROVISIONING_PROFILE_SPECIFIER="
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
    EXPORT_SIGNING_STYLE=manual
fi

# notarytool helper — abstracts API-key vs keychain-profile auth.
notarize() {
    if [ -n "$APPLE_API_KEY_PATH" ]; then
        xcrun notarytool submit "$1" \
            --key "$APPLE_API_KEY_PATH" \
            --key-id "$APPLE_API_KEY_ID" \
            --issuer "$APPLE_API_ISSUER_ID" \
            --wait
    else
        xcrun notarytool submit "$1" --keychain-profile star --wait
    fi
}

rm -rf ${BUILD_DIR}

mkdir ${BUILD_DIR}

# set the app version 
perl -pi -e "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${STAR_VERSION}/" star.xcodeproj/project.pbxproj

# set flag to build for all archs
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  star.xcodeproj/project.pbxproj

# build the archive
xcodebuild \
    -project "star.xcodeproj" \
    -scheme "Star Release" \
    -configuration "Release" \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    "${XCODEBUILD_SIGNING_ARGS[@]}" \
    archive

# Under manual signing we have to name the cert explicitly; under automatic
# signing Xcode picks it from the team's account. The signingCertificate key
# is ignored when signingStyle=automatic, so it's safe to always include it.
cat > "${BUILD_DIR}/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>signingCertificate</key>
    <string>${SIGN_APP}</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
EOF

echo "exporting archive"

# export the archive
xcodebuild \
    -exportArchive \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    -exportPath "${BUILD_DIR}/AdHoc"

# create zip file for notorization
ditto \
    -c -k --sequesterRsrc --keepParent \
    "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
    "${BUILD_DIR}/${APP_NAME}-for-notarization.zip"



# notarize it

# run this again to get another keychain profile item with an app specific password, used by:
#
#   --keychain-profile "star" \
#
# Sign in to appleid.apple.com.
# In the Sign-In and Security section, select App-Specific Passwords.
# Select Generate an app-specific password or select the Add button. 
# then follow the steps on your screen.
# afterwards, run this:
#
# xcrun notarytool store-credentials --apple-id brian.beholden@gmail.com --team-id G3L75S65V9
#
# Be aware that this can fail due to updated developer account legal stuff, try logging into
# developer.apple.com and clicking around before generating a new app specific password 
#

notarize "${BUILD_DIR}/${APP_NAME}-for-notarization.zip"

WAIT_TIME=20

# wait for notorization and staple the build
until xcrun stapler staple "${BUILD_DIR}/AdHoc/${APP_NAME}.app"; do
    echo "wait ${WAIT_TIME} seconds..."
    sleep ${WAIT_TIME}
done

# package it up for distribution
pkgbuild --root "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
	 --identifier com.star \
	 --version "${STAR_VERSION}" \
	 --install-location /Applications/${APP_NAME}.app \
 	 --sign "$SIGN_PKG" \
	 $PKG_NAME

# not sure if we need to notarize and staple both the app and the package,
# seems to work now, adjust as if necessary later
notarize "$PKG_NAME"
xcrun stapler staple $PKG_NAME

# set to build for active arch only for development (as it is in git)
perl -pi -e 's/ONLY_ACTIVE_ARCH = NO/ONLY_ACTIVE_ARCH = YES/'  star.xcodeproj/project.pbxproj


echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
