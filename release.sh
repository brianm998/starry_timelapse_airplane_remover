#!/bin/bash

####
# first build the decision tree code into a static, universal library (.a file)
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
# .build/apple/Products/Release/ntar


####
# next build a .app dir from the gui
####



####
# then package that and the cli app into a file with a readme and installer script
####



####
# then zip that up with a release number somehow
####

# push it automatically to github as a release from the cli?
