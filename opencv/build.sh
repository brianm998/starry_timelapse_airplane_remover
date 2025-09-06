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
export OPENCV_VERSION="4.12.0"

# clean any prior build
rm -rf lib
rm -rf include
rm -rf opencv
rm -rf opencv2.framework

# output dirs
mkdir lib
mkdir include

# the default MACOSX deployment target is too low, so set it higher here for a successful compile
export MACOSX_DEPLOYMENT_TARGET='14'

# clone latest opencv
git clone https://github.com/opencv/opencv.git
cd opencv

# checkout release tag
git checkout $OPENCV_VERSION


# this is the only reliable way to set the C++ standard to 17, which is required for this to compile
sed -i '' '1i\
set(CMAKE_CXX_STANDARD 17) ## HACK HACK
' CMakeLists.txt

# split ARCHS into array
IFS=',' read -r -a ARCH_ARRAY <<< "$ARCHS"

# function to build a single architecture
build_arch() {
    local ARCH=$1
    echo "Building OpenCV for $ARCH..."
    python3 platforms/osx/build_framework.py "FRAMEWORK_BUILD_$ARCH" --macos_archs "$ARCH" \
        --without objc --without dnn_tf --without dnn --without gapi --without java \
        --without js --without ml --without objdetect --without photo --without python \
        --without stitching --without ts --without video --without videoio --without world \
        --build_only_specified_archs True
}

# build all architectures in parallel
for ARCH in "${ARCH_ARRAY[@]}"; do
    build_arch "$ARCH" &
done

# wait for all parallel builds to complete
wait

# create universal binary if multiple architectures
if [ "${#ARCH_ARRAY[@]}" -gt 1 ]; then
    # if we are building more than one platform, package up the .a files for both as a universal binary
    LIPO_INPUTS=()
    for ARCH in "${ARCH_ARRAY[@]}"; do
        LIPO_INPUTS+=("FRAMEWORK_BUILD_$ARCH/build/build-$ARCH-macosx/lib/Release/libopencv_merged.a")
    done
    lipo "${LIPO_INPUTS[@]}" -create -output ../lib/libopencv2.a
else
    # for development we can just use one platform
    cp "FRAMEWORK_BUILD_${ARCH_ARRAY[0]}/build/build-${ARCH_ARRAY[0]}-macosx/lib/Release/libopencv_merged.a" ../lib/libopencv2.a
fi

mv "FRAMEWORK_BUILD_${ARCH_ARRAY[0]}/opencv2.framework" ..
cd ..
cd include
mkdir opencv2
cd opencv2

# link in header files for proper compilation
ln -s ../../opencv2.framework/Headers/* .



