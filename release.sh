#!/bin/bash

# this script produces a new release of ntar
#
# created are a zip file in releases/ and local and remote release tags

set -e

####
# first build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into both the gui and cli apps
####
cd NtarDecisionTrees
rm -rf .build

# build for x86
swift build --configuration release --arch x86_64 -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
mv *.a .build/x86_64-apple-macosx

# build for arm64
swift build --configuration release --arch arm64  -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
mv *.a .build/arm64-apple-macosx

# lipo them together into a universal .a file for both archs
lipo .build/arm64-apple-macosx/libNtarDecisionTrees.a \
     .build/x86_64-apple-macosx/libNtarDecisionTrees.a \
     -create -output libNtarDecisionTrees.a

cd ..

####
# next build a universal (all arch) binary for the cli     
####
cd cli
./release.sh
cd ..

# result ends up here:
# cli/.build/ntar_cli_${NTAR_VERSION}.pkg"


####
# next build a .app dir from the gui
####
cd gui
./release.sh
cd ..

# results end up here:
# gui/.build/ntar_app_${NTAR_VERSION}.pkg"


####
# package the gui and cli apps into a single zip file with version from ntar config in its name
####

./finishRelease.sh

# output should be in releases/ntar-${NTAR_VERSION}.zip
# tag release/${NTAR_VERSION} should be on both local and remote
