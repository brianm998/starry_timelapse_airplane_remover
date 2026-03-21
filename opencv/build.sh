#!/bin/bash

# this script builds opencv2 so we can use it.
#
# On macOS:
#   ARCHS can be set to "arm64", "x86_64", or "x86_64,arm64"
#   If not set, defaults to the current architecture.
#   Uses the opencv osx build_framework.py script.
#
# On Linux:
#   Builds with cmake directly for the current architecture.
#
# We need to build a static .a file so we don't have to sign it separately from the app itself.
# apple's signing of frameworks included in apps is obtuse, and can be hard to satisfy.
# Building opencv as a .a file means that it gets linked directly into the star binary,
# making separate signing of opencv2 unnecessary.

set -e

# detect platform
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin) PLATFORM_DIR="macos" ;;
    Linux)  PLATFORM_DIR="linux" ;;
    *)      echo "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

# if ARCHS is not already set, default it to the current platform
if [ -z ${ARCHS+x} ]; then export ARCHS=`uname -m`; fi

# in theory we could track later versions, but this seems to work fine for what we need.
export OPENCV_VERSION="4.12.0"

# clean any prior build for this platform
rm -rf lib/$PLATFORM_DIR
rm -rf opencv

# output dirs
mkdir -p lib/$PLATFORM_DIR

# the include/ dir is platform-independent (headers are the same)
mkdir -p include

# the default MACOSX deployment target is too low, so set it higher here for a successful compile
if [ "$PLATFORM" = "Darwin" ]; then
    export MACOSX_DEPLOYMENT_TARGET='14'
fi

# clone latest opencv
git clone https://github.com/opencv/opencv.git
cd opencv

# checkout release tag
git checkout $OPENCV_VERSION

# this is the only reliable way to set the C++ standard to 17, which is required for this to compile
if [ "$PLATFORM" = "Darwin" ]; then
    sed -i '' '1i\
set(CMAKE_CXX_STANDARD 17) ## HACK HACK
' CMakeLists.txt
else
    sed -i '1i set(CMAKE_CXX_STANDARD 17) ## HACK HACK' CMakeLists.txt
fi

if [ "$PLATFORM" = "Darwin" ]; then
    #
    # macOS build via build_framework.py
    #

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
        LIPO_INPUTS=()
        for ARCH in "${ARCH_ARRAY[@]}"; do
            LIPO_INPUTS+=("FRAMEWORK_BUILD_$ARCH/build/build-$ARCH-macosx/lib/Release/libopencv_merged.a")
        done
        lipo "${LIPO_INPUTS[@]}" -create -output ../lib/$PLATFORM_DIR/libopencv2.a
    else
        cp "FRAMEWORK_BUILD_${ARCH_ARRAY[0]}/build/build-${ARCH_ARRAY[0]}-macosx/lib/Release/libopencv_merged.a" ../lib/$PLATFORM_DIR/libopencv2.a
    fi

    mv "FRAMEWORK_BUILD_${ARCH_ARRAY[0]}/opencv2.framework" ..
    cd ..

    # set up headers (from framework)
    rm -rf include/opencv2
    cd include
    mkdir opencv2
    cd opencv2
    ln -s ../../opencv2.framework/Headers/* .

else
    #
    # Linux build via cmake directly
    #

    mkdir -p build_linux && cd build_linux

    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_LIST=core,imgproc,imgcodecs,features2d,calib3d,flann,highgui \
        -DBUILD_opencv_apps=OFF \
        -DBUILD_opencv_java=OFF \
        -DBUILD_opencv_python3=OFF \
        -DBUILD_opencv_python2=OFF \
        -DBUILD_opencv_js=OFF \
        -DBUILD_opencv_objc=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_PERF_TESTS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_DOCS=OFF \
        -DWITH_GTK=OFF \
        -DWITH_QT=OFF \
        -DWITH_FFMPEG=OFF \
        -DWITH_V4L=OFF \
        -DWITH_OPENCL=OFF \
        -DWITH_CUDA=OFF \
        -DWITH_1394=OFF \
        -DWITH_GSTREAMER=OFF \
        -DWITH_OPENEXR=OFF \
        -DWITH_WEBP=OFF \
        -DWITH_JASPER=OFF \
        -DWITH_OPENJPEG=OFF \
        -DBUILD_ZLIB=ON \
        -DBUILD_PNG=ON \
        -DBUILD_TIFF=ON \
        -DBUILD_JPEG=ON \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON

    make -j$(nproc)

    # merge all static libs into one
    # collect all .a files produced by the build
    LIBS=$(find lib -name '*.a' -o -name '*.a' -path '*/3rdparty/*.a' | sort)
    THIRD_PARTY=$(find 3rdparty -name '*.a' 2>/dev/null | sort)
    ALL_LIBS="$LIBS $THIRD_PARTY"

    # create a merged static library using ar
    mkdir -p merged_tmp
    cd merged_tmp
    for lib in $ALL_LIBS; do
        ar x "../$lib"
    done
    ar rcs ../../lib/$PLATFORM_DIR/libopencv2.a *.o
    cd ..
    rm -rf merged_tmp

    cd ../..  # back to opencv/

    # set up headers (from source + generated)
    rm -rf include/opencv2
    mkdir -p include/opencv2

    # copy generated cvconfig.h and opencv_modules.hpp
    cp opencv/build_linux/cvconfig.h include/opencv2/
    cp opencv/build_linux/opencv2/opencv_modules.hpp include/opencv2/

    # copy public headers from the modules we built
    for mod in core imgproc imgcodecs features2d calib3d flann highgui; do
        if [ -d "opencv/modules/$mod/include/opencv2" ]; then
            cp -r opencv/modules/$mod/include/opencv2/* include/opencv2/
        fi
    done
fi
