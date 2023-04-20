#!/bin/bash

# die on any error
set -e

# move the assembled packages to releases distribution
# also tag this release in git with the version from Config.swift

NTAR_VERSION=`cd NtarCore ; perl version.pl`
GUI_PKG_NAME="gui/.build/ntar_app_${NTAR_VERSION}.pkg"
CLI_PKG_NAME="cli/.build/ntar_cli_${NTAR_VERSION}.pkg"

# move packages to the releases dir
mv $GUI_PKG_NAME releases
mv $CLI_PKG_NAME releases

# tag this release in the local repo
git tag "release/${NTAR_VERSION}"

# push that tag remote
git push origin "release/${NTAR_VERSION}"

# named zip file of this release is now in releases dir

echo "git tag releases/${NTAR_VERSION} created and pushed to remove"
echo "packages for ntar release ${NTAR_VERSOIN} are in releases/ dir"
