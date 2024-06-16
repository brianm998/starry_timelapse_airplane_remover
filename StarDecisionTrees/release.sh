#!/bin/bash

set -e

####
# build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into the gui and cli apps, as into the
# decision tree generator.  It can take hours to build a large set of trees,
# due to a number of factors:
#  - decision trees are REALLY big swift files
#  - compling with optimization on is slow
#  - we have to compile the same thing three times here:
#    1. get universal swift module definition
#    2. get x86 .a file
#    3. get arm .a file
#  building both archs at once only gives us a .o file, fixing that would speed this up 3x
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




