#!/bin/bash

set -e

# build and notarize with apple the ntar gui code for ad hoc distribution

BUILD_DIR=.build
APP_NAME=ntar
NTAR_VERSION=`cd ../NtarCore ; perl version.pl`
PKG_NAME=".build/ntar_app_${NTAR_VERSION}.pkg"

rm -rf ${BUILD_DIR}

mkdir ${BUILD_DIR}

pod install

# FIX annoying cocoapod deployment target issue
perl -pi -e 's/MACOSX_DEPLOYMENT_TARGET = \d+[.]?\d*/MACOSX_DEPLOYMENT_TARGET = 12.0/'  Pods/Pods.xcodeproj/project.pbxproj

# FIX annother annoying cocoapods problem
perl -pi -e 's/readlink/readlink -f/' Pods/Target\ Support\ Files/Pods-ntar/Pods-ntar-frameworks.sh

# set the app version 
perl -pi -e "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${NTAR_VERSION}/" ntar.xcodeproj/project.pbxproj

# set flag to build for all archs
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  ntar.xcodeproj/project.pbxproj

# build the archive
xcodebuild \
    -workspace "ntar.xcworkspace" \
    -scheme "ntar" \
    -configuration "Release" \
    -archivePath "${BUILD_DIR}/ntar.xcarchive" \
    archive

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
    <string>automatic</string>
</dict>
</plist>
EOF

echo "exporting archive"

# export the archive
xcodebuild \
    -exportArchive \
    -archivePath "${BUILD_DIR}/ntar.xcarchive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    -exportPath "${BUILD_DIR}/AdHoc"

# create zip file for notorization
ditto \
    -c -k --sequesterRsrc --keepParent \
    "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
    "${BUILD_DIR}/AdHoc/${APP_NAME}-for-notarization.zip"

# notarize it

# run this again to get another keychain profile item with an app specific password, used by:
#
#   --keychain-profile "ntar" \
#
# xcrun notarytool store-credentials --apple-id brian.beholden@gmail.com --team-id G3L75S65V9

xcrun notarytool submit \
      "${BUILD_DIR}/AdHoc/${APP_NAME}-for-notarization.zip" \
      --keychain-profile "ntar" \
      --wait 

WAIT_TIME=20

# wait for notorization and staple the build
until xcrun stapler staple "${BUILD_DIR}/AdHoc/${APP_NAME}.app"; do
    echo "wait ${WAIT_TIME} seconds..."
    sleep ${WAIT_TIME}
done

# package it up for distribution
pkgbuild --root "${BUILD_DIR}/AdHoc" \
	 --identifier com.ntar \
	 --version "${NTAR_VERSION}" \
	 --install-location / \
 	 --sign "Developer ID Installer: Brian Martin (G3L75S65V9)" \
	 $PKG_NAME

# not sure if we need to notarize and staple both the app and the package,
# seems to work now, adjust as if necessary later
xcrun notarytool submit $PKG_NAME --keychain-profile ntar --wait
xcrun stapler staple $PKG_NAME

# set to build for active arch only for development (as it is in git)
perl -pi -e 's/ONLY_ACTIVE_ARCH = NO/ONLY_ACTIVE_ARCH = YES/'  ntar.xcodeproj/project.pbxproj


echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
