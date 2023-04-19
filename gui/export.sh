#!/bin/bash

# build and notarize with apple the ntar gui code for ad hoc distribution

BUILD_DIR=.build
APP_NAME=ntar

rm -rf ${BUILD_DIR}

mkdir ${BUILD_DIR}

pod install

# FIX annoying cocoapod deployment target issue
perl -pi -e 's/MACOSX_DEPLOYMENT_TARGET = \d+[.]?\d*/MACOSX_DEPLOYMENT_TARGET = 12.0/'  Pods/Pods.xcodeproj/project.pbxproj

# FIX annother annoying cocoapods problem
perl -pi -e 's/readlink/readlink -f/' Pods/Target\ Support\ Files/Pods-ntar/Pods-ntar-frameworks.sh

# set flag to build for all archs
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  ntar.xcodeproj/project.pbxproj

# build the archive
xcodebuild \
    -workspace "ntar.xcworkspace" \
    -scheme "ntar" \
    -configuration "Release" \
    -archivePath "${BUILD_DIR}/ntar.xcarchive" \
    archive

cat > "${BUILD_DIR}/ExportOptiopns.plist" <<EOF
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
    -exportOptionsPlist "${BUILD_DIR}/ExportOptiopns.plist" \
    -exportPath "${BUILD_DIR}/AdHoc"

# create zip file for notorization
ditto \
    -c -k --sequesterRsrc --keepParent \
    "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
    "${BUILD_DIR}/AdHoc/${APP_NAME}-for-notarization.zip"

# XXX add a version number in here (get it from the config in code)

# notarize it (should check for these env vars before starting)

xcrun notarytool submit "${BUILD_DIR}/AdHoc/${APP_NAME}-for-notarization.zip" \
                   --keychain-profile "${APPSTORE_PASSWORD}" \
                   --wait 

WAIT_TIME=60

# wait for notorization and staple the build
until xcrun stapler staple "${BUILD_DIR}/AdHoc/${APP_NAME}.app"; do
    echo "wait ${WAIT_TIME} seconds..."
    sleep ${WAIT_TIME}
done

# set to build for active arch only for development (as it is in git)
perl -pi -e 's/ONLY_ACTIVE_ARCH = NO/ONLY_ACTIVE_ARCH = YES/'  ntar.xcodeproj/project.pbxproj

ditto \
    -c -k --sequesterRsrc --keepParent \
    "${BUILD_DIR}/AdHoc/${APP_NAME}.app" \
    "${BUILD_DIR}/${APP_NAME}.zip"


echo "results in ${BUILD_DIR}/AdHoc/${APP_NAME}.app"
