#!/bin/bash

set -e

NTAR_VERSION=`cd ../NtarCore ; perl version.pl`
CLI_PKG_NAME=".build/ntar_cli_${NTAR_VERSION}.pkg"

rm -rf .build
mkdir .build

time xcodebuild \
     -workspace ntar.xcworkspace \
     -scheme ntar \
     -configuration Release \
     -archivePath .build/ntar \
     archive

pkgbuild --root .build/ntar.xcarchive/Products \
	 --identifier com.ntar \
	 --version "${NTAR_VERSION}" \
	 --install-location / \
	 --sign "Developer ID Installer: Brian Martin (G3L75S65V9)" \
	 $CLI_PKG_NAME

xcrun notarytool submit $CLI_PKG_NAME --keychain-profile ntar --wait
xcrun stapler staple $CLI_PKG_NAME

