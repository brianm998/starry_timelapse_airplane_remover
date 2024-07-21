#!/bin/bash

# this script builds opencv2 so we can use it.
#
# it has to be a static .a file so we don't have to sign it.
# apple's signing of frameworks included in apps is hard to get around.
# having opencv as a .a file gets it linked directly into the star binary,
# making separate signing of opencv2 unnecessary.

set -e

# clean any prior build
rm -rf lib
rm -rf include
rm -rf opencv
rm -rf opencv2.framework

mkdir lib
mkdir include

# clone latest opencv
git clone https://github.com/opencv/opencv.git
cd opencv

# checkout release tag
git checkout 4.10.0

# build opencv2 framework for osx, both x86 and arm
time python3 platforms/osx/build_framework.py --out FRAMEWORK_BUILD --macos_archs x86_64,arm64 --without objc --build_only_specified_archs True

# next package up the .a files for both dirs as a universal binary
lipo FRAMEWORK_BUILD/build/build-arm64-macosx/lib/Release/libopencv_merged.a \
     FRAMEWORK_BUILD/build/build-x86_64-macosx/lib/Release/libopencv_merged.a \
     -create -output ../lib/libopencv2.a

mv FRAMEWORK_BUILD/opencv2.framework ..
cd ..
cd include
mkdir opencv2
cd opencv2

# link in header files for proper compilation
ln -s ../../opencv2.framework/Headers/* .



