#!/bin/bash

set -e

STAR_VERSION=`cd ../StarCore ; perl version.pl`
PKG_NAME=".build/star_cli_${STAR_VERSION}.pkg"

rm -rf .build
mkdir .build

# make sure the flag to build for all archs is set (should be, but just make sure)
perl -pi -e 's/ONLY_ACTIVE_ARCH = YES/ONLY_ACTIVE_ARCH = NO/'  star.xcodeproj/project.pbxproj

# build an archive of the cli app
time xcodebuild \
     -project star.xcodeproj \
     -scheme star \
     -configuration Release \
     -archivePath .build/star \
     archive

# could probably build this without xcode (swift directly) if we code sign it afterwards
# with the 'Developer ID Application' identity after compilation and before pkgbuild below

# package it up for distribution
pkgbuild --root .build/star.xcarchive/Products/usr/local/bin \
	 --identifier com.star \
	 --version "${STAR_VERSION}" \
	 --install-location /usr/local/bin \
	 --sign "Developer ID Installer: Brian Martin (G3L75S65V9)" \
	 $PKG_NAME

# notarize it with apple
xcrun notarytool submit $PKG_NAME --keychain-profile star --wait

# staple it as notarized
xcrun stapler staple $PKG_NAME

echo "signed, notarized and stapled results packaged up in ${PKG_NAME}"
