#!/bin/bash

set -e

NTAR_VERSION=`cd ../NtarCore ; perl version.pl`
PKG_NAME=".build/ntar_cli_${NTAR_VERSION}.pkg"

rm -rf .build
mkdir .build

# make sure the flag to build for all archs is set (should be, but just make sure)
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  ntar.xcodeproj/project.pbxproj

# build an archive of the cli app
time xcodebuild \
     -project ntar.xcodeproj \
     -scheme ntar \
     -configuration Release \
     -archivePath .build/ntar \
     archive

# package it up for distribution
pkgbuild --root .build/ntar.xcarchive/Products \
	 --identifier com.ntar \
	 --version "${NTAR_VERSION}" \
	 --install-location / \
	 --sign "Developer ID Installer: Brian Martin (G3L75S65V9)" \
	 $PKG_NAME

# notarize it with apple
xcrun notarytool submit $PKG_NAME --keychain-profile ntar --wait

# staple it as notarized
xcrun stapler staple $PKG_NAME

echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
