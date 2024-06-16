#!/bin/bash

set -e

####
# build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into the gui and cli apps, as into the
# decision tree generator.  This can take hours on a large set of trees.
####

# clear out any previous build
rm -rf .build
rm -rf lib/release
rm -rf include/release

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

# build static, universal, speed optimized lib 

# create output dirs
mkdir -p lib/release
mkdir -p include/release

# this only produces the swift module for both arches (which we need),
# and a .o file, which is useless
swift build --configuration release -Xswiftc -O  --arch x86_64 --arch arm64

mv .build/apple/Products/Release/StarDecisionTrees.swiftmodule include/release

# build the real .a file

# first for x86
swift build --configuration release -Xswiftc -O --arch x86_64

# next for arm
swift build --configuration release -Xswiftc -O --arch arm64

# then lipo them together
lipo .build/arm64-apple-macosx/release/libStarDecisionTrees.a \
     .build/x86_64-apple-macosx/release/libStarDecisionTrees.a \
      -create -output lib/release/libStarDecisionTrees.a




