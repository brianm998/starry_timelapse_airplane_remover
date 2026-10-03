#!/bin/bash

set -e

# build star gui for local testing — no notarization, active arch only

# stop here, saying what to fix, if a prerequisite is missing; this has to come
# before anything below touches the build dir or the Xcode project
source "$(dirname "$0")/../preflight.sh"
preflight_eigen
preflight_decision_trees_release
preflight_gui_videos
preflight_finish

BUILD_DIR=.build
APP_NAME=Star
STAR_VERSION=`cd ../StarCore ; perl version.pl`

rm -rf ${BUILD_DIR}
mkdir ${BUILD_DIR}

perl -pi -e "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = ${STAR_VERSION}/" star.xcodeproj/project.pbxproj

xcodebuild \
    -project "star.xcodeproj" \
    -scheme "Star Release" \
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

xcodebuild \
    -exportArchive \
    -archivePath "${BUILD_DIR}/star.xcarchive" \
    -exportOptionsPlist "${BUILD_DIR}/ExportOptions.plist" \
    -exportPath "${BUILD_DIR}/AdHoc"

echo "local build done: ${BUILD_DIR}/AdHoc/${APP_NAME}.app"
