#!/bin/bash

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


####
# next build a universal (all arch) binary for the cli     
####
cd ../cli
rm -rf .build
# build x86 and arm into a single universal binary
swift build --configuration release --arch arm64 --arch x86_64

# result ends up here:
# cli/.build/apple/Products/Release/ntar


####
# next build a .app dir from the gui
####

cd ../gui
./release.sh

# results end up here:
# gui/.build/AdHoc/${APP_NAME}.app"
# gui/.build/${APP_NAME}.zip"

####
# package the gui and cli apps into a single zip file with version from ntar config in its name
####

./finishRelease.sh

