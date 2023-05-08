#!/bin/bash

set -e

# build and notarize with apple the star gui code for ad hoc distribution

BUILD_DIR=.build
APP_NAME=Star
STAR_VERSION=`cd ../StarCore ; perl version.pl`
PKG_NAME=".build/star_app_${STAR_VERSION}.pkg"

rm -rf ${BUILD_DIR}

mkdir ${BUILD_DIR}

pod install

# FIX annoying cocoapod deployment target issue
perl -pi -e 's/MACOSX_DEPLOYMENT_TARGET = \d+[.]?\d*/MACOSX_DEPLOYMENT_TARGET = 12.0/'  Pods/Pods.xcodeproj/project.pbxproj

# FIX annother annoying cocoapods problem
perl -pi -e 's/readlink/readlink -f/' Pods/Target\ Support\ Files/Pods-star/Pods-star-frameworks.sh

# set the app version 
perl -pi -e "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${STAR_VERSION}/" star.xcodeproj/project.pbxproj

# set flag to build for all archs
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  star.xcodeproj/project.pbxproj

# build the archive
xcodebuild \
    -workspace "star.xcworkspace" \
    -scheme "star" \
    -configuration "Release" \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
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
# xcrun notarytool store-credentials --apple-id brian.beholden@gmail.com --team-id G3L75S65V9

xcrun notarytool submit \
      "${BUILD_DIR}/${APP_NAME}-for-notarization.zip" \
      --keychain-profile "ntar" \
      --wait 

WAIT_TIME=20

# wait for notorization and staple the build
until xcrun stapler staple "${BUILD_DIR}/AdHoc/${APP_NAME}.app"; do
    echo "wait ${WAIT_TIME} seconds..."
    sleep ${WAIT_TIME}
done

COMPONENT_PLIST="${BUILD_DIR}/component_list.plist"

pkgbuild --analyze --root "${BUILD_DIR}/AdHoc/${APP_NAME}.app" $COMPONENT_PLIST

# package it up for distribution
pkgbuild --root "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
         --component-plist $COMPONENT_PLIST \
	 --identifier com.star \
	 --version "${STAR_VERSION}" \
	 --install-location /Applications/${APP_NAME}.app \
 	 --sign "Developer ID Installer: Brian Martin (G3L75S65V9)" \
	 $PKG_NAME

# not sure if we need to notarize and staple both the app and the package,
# seems to work now, adjust as if necessary later
xcrun notarytool submit $PKG_NAME --keychain-profile ntar --wait
xcrun stapler staple $PKG_NAME

# set to build for active arch only for development (as it is in git)
perl -pi -e 's/ONLY_ACTIVE_ARCH = NO/ONLY_ACTIVE_ARCH = YES/'  star.xcodeproj/project.pbxproj


echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
