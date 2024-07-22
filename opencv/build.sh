#!/bin/bash

# this script builds opencv2 so we can use it.
#
# It expects the ARCHS enviornment variable to set to one of
#  - arm64
#  - x86_64
#  - x86_64,arm64
#  or if not set, will default to the current architecture
#
# We need to build a static .a file so we don't have to sign it separately from the app itself.
# apple's signing of frameworks included in apps is obtuse, and can be hard to satisfy.
# Building opencv as a .a file means that it gets linked directly into the star binary,
# making separate signing of opencv2 unnecessary.

set -e

# if ARCHS is not already set, default it to the current platform
if [ -z ${ARCHS+x} ]; then export ARCHS=`uname -m`; fi

# in theory we could track later versions, but this seems to work fine for what we need.
export OPENCV_VERSION="4.10.0"

# clean any prior build
rm -rf lib
rm -rf include
rm -rf opencv
rm -rf opencv2.framework

# output dirs
mkdir lib
mkdir include

# clone latest opencv
git clone https://github.com/opencv/opencv.git
cd opencv

# checkout release tag
git checkout $OPENCV_VERSION

# build opencv2 framework for osx, both x86 and arm
time python3 platforms/osx/build_framework.py --out FRAMEWORK_BUILD --macos_archs $ARCHS --without objc --build_only_specified_archs True

if [ "$ARCHS" = "x86_64,arm64" ]; then 
    # if we are building more than one platform, package up the .a files for both as a universal binary
    lipo FRAMEWORK_BUILD/build/build-arm64-macosx/lib/Release/libopencv_merged.a \
	 FRAMEWORK_BUILD/build/build-x86_64-macosx/lib/Release/libopencv_merged.a \
	 -create -output ../lib/libopencv2.a
else
    # for development we can just use one platform
    cp "FRAMEWORK_BUILD/build/build-$ARCHS-macosx/lib/Release/libopencv_merged.a" \
       ../lib/libopencv2.a
fi

mv FRAMEWORK_BUILD/opencv2.framework ..
cd ..
cd include
mkdir opencv2
cd opencv2

# link in header files for proper compilation
ln -s ../../opencv2.framework/Headers/* .



