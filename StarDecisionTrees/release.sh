#!/bin/bash

set -e

####
# build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into the gui and cli apps, as into the
# decision tree generator.  This can take hours on a large set of trees.
####

# clear out any previous build
rm -rf .build
rm -rf lib
rm -rf include

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

BUILD_COMMAND="swift build --configuration release"
BUILD_ARGS="-Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O"
STATIC_X86_BUILD="$BUILD_COMMAND --arch x86_64 $BUILD_ARGS"
STATIC_ARM_BUILD="$BUILD_COMMAND --arch arm64 $BUILD_ARGS"

# build static, speed optimized lib for x86

# run it like this incase the first one dies because of missing objc header 
$STATIC_X86_BUILD || $STATIC_X86_BUILD

mv *.a .build/x86_64-apple-macosx

# build static, speed optimized lib for arm64
$STATIC_ARM_BUILD || $STATIC_ARM_BUILD

mv *.a .build/arm64-apple-macosx

mkdir -p lib/release

# lipo them together into a universal .a file for both archs
lipo .build/arm64-apple-macosx/libStarDecisionTrees.a \
     .build/x86_64-apple-macosx/libStarDecisionTrees.a \
     -create -output lib/release/libStarDecisionTrees.a

# move swift module definitions to include dir
mkdir -p include/debug
cp -r .build/debug/StarDecisionTrees* include/debug

mkdir -p include/release
cp -r .build/release/StarDecisionTrees* include/release




