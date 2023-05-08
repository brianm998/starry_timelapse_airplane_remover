#!/bin/bash

# die on any error
set -e

# move the assembled packages to releases distribution
# also tag this release in git with the version from Config.swift

STAR_VERSION=`cd StarCore ; perl version.pl`
GUI_PKG_NAME="gui/.build/star_app_${STAR_VERSION}.pkg"
CLI_PKG_NAME="cli/.build/star_cli_${STAR_VERSION}.pkg"

# move packages to the releases dir
mv $GUI_PKG_NAME releases
mv $CLI_PKG_NAME releases

# tag this release in the local repo
git tag "release/${STAR_VERSION}"

# push that tag remote
git push origin "release/${STAR_VERSION}"

# named zip file of this release is now in releases dir

echo "git tag releases/${STAR_VERSION} created and pushed to remove"
echo "packages for star release ${STAR_VERSOIN} are in releases/ dir"
