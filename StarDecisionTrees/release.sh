#!/bin/bash

set -e

####
# build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into both the gui and cli apps
####

rm -rf .build

# build static, speed optimized lib for x86
swift build --configuration release --arch x86_64 -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O
mv *.a .build/x86_64-apple-macosx

# build static, speed optimized lib for arm64
swift build --configuration release --arch arm64  -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O 
mv *.a .build/arm64-apple-macosx

# lipo them together into a universal .a file for both archs
lipo .build/arm64-apple-macosx/libStarDecisionTrees.a \
     .build/x86_64-apple-macosx/libStarDecisionTrees.a \
     -create -output libStarDecisionTrees.a

# can't properly build against this with these still here
rm -rf .build/debug/*.build
rm -rf .build/release/*.build

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl
