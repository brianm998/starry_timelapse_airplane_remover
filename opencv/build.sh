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
#
# Build caching:
#   The opencv source and build directories are preserved between runs so that
#   cmake's feature-test results (the slow "Looking for ..." checks) are cached.
#   Only a fresh git clone happens when the version changes.
#   Pass CLEAN=1 to force a full rebuild:  CLEAN=1 ./build.sh

set -e

# Anchor the script to its own directory. Without this, invoking the script
# from anywhere other than opencv/ — e.g. `bash opencv/build.sh` from the
# repo root — would make the relative `rm -rf opencv` in the CLEAN block and
# in the version-mismatch branch resolve to `<cwd>/opencv`, which on the
# project root is THIS script's own directory. Result: the script deletes
# itself (and README.md, lib/, etc.) the moment a clean/version-bump fires.
# cd up front so every relative path below is rooted at opencv/.
cd "$(dirname "${BASH_SOURCE[0]}")"

# detect platform
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin)    PLATFORM_DIR="macos" ;;
    Linux)     PLATFORM_DIR="linux" ;;
    MINGW*|MSYS_NT*) PLATFORM_DIR="windows" ;;
    *)         echo "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

# if ARCHS is not already set, default it to the current platform
if [ -z ${ARCHS+x} ]; then export ARCHS=`uname -m`; fi

# in theory we could track later versions, but this seems to work fine for what we need.
export OPENCV_VERSION="4.12.0"

# ── decide whether to do a clean build ────────────────────────────────
NEED_CLONE=0

if [ "${CLEAN:-0}" = "1" ]; then
    echo "==> CLEAN=1 requested, doing full rebuild"
    rm -rf lib/$PLATFORM_DIR
    rm -rf include
    rm -rf opencv
    rm -rf opencv2.framework
    NEED_CLONE=1
elif [ ! -d opencv ]; then
    NEED_CLONE=1
else
    # check if existing clone is at the right version
    CURRENT_VERSION=$(cd opencv && git describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [ "$CURRENT_VERSION" != "$OPENCV_VERSION" ]; then
        echo "==> OpenCV version changed ($CURRENT_VERSION -> $OPENCV_VERSION), doing fresh clone"
        rm -rf opencv
        NEED_CLONE=1
    elif [ ! -f opencv/CMakeLists.txt ]; then
        echo "==> OpenCV source corrupt (CMakeLists.txt missing), forcing fresh clone"
        rm -rf opencv
        NEED_CLONE=1
    else
        echo "==> Reusing existing OpenCV $OPENCV_VERSION source and build caches"
    fi
fi

# always ensure output dirs exist
mkdir -p lib/$PLATFORM_DIR
mkdir -p include

# the default MACOSX deployment target is too low, so set it higher here for a successful compile
if [ "$PLATFORM" = "Darwin" ]; then
    export MACOSX_DEPLOYMENT_TARGET='14'
fi

# ── clone and patch if needed ─────────────────────────────────────────
if [ "$NEED_CLONE" = "1" ]; then
    git clone https://github.com/opencv/opencv.git
    cd opencv
    git checkout $OPENCV_VERSION

    # this is the only reliable way to set the C++ standard to 17, which is required for this to compile
    if [ "$PLATFORM" = "Darwin" ]; then
        sed -i '' '1i\
set(CMAKE_CXX_STANDARD 17) ## HACK HACK
' CMakeLists.txt

        # Fix OpenCV 4.12.0 cmake bug: ocv_add_definition macro fails when Eigen
        # version variables are empty (e.g. "ver ..").  The macro requires exactly
        # 2 args, but empty ${EIGEN_*_VERSION} expands to nothing.
        # Fix: quote the Eigen version variables at the call sites.
        sed -i '' \
            's/ocv_add_definition(EIGEN_WORLD_VERSION ${EIGEN_WORLD_VERSION})/ocv_add_definition(EIGEN_WORLD_VERSION "${EIGEN_WORLD_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
        sed -i '' \
            's/ocv_add_definition(EIGEN_MAJOR_VERSION ${EIGEN_MAJOR_VERSION})/ocv_add_definition(EIGEN_MAJOR_VERSION "${EIGEN_MAJOR_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
        sed -i '' \
            's/ocv_add_definition(EIGEN_MINOR_VERSION ${EIGEN_MINOR_VERSION})/ocv_add_definition(EIGEN_MINOR_VERSION "${EIGEN_MINOR_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
    else
        sed -i '1i set(CMAKE_CXX_STANDARD 17) ## HACK HACK' CMakeLists.txt

        sed -i \
            's/ocv_add_definition(EIGEN_WORLD_VERSION ${EIGEN_WORLD_VERSION})/ocv_add_definition(EIGEN_WORLD_VERSION "${EIGEN_WORLD_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
        sed -i \
            's/ocv_add_definition(EIGEN_MAJOR_VERSION ${EIGEN_MAJOR_VERSION})/ocv_add_definition(EIGEN_MAJOR_VERSION "${EIGEN_MAJOR_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
        sed -i \
            's/ocv_add_definition(EIGEN_MINOR_VERSION ${EIGEN_MINOR_VERSION})/ocv_add_definition(EIGEN_MINOR_VERSION "${EIGEN_MINOR_VERSION}")/' \
            cmake/OpenCVBindingsPreprocessorDefinitions.cmake
    fi
else
    cd opencv
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

    rm -rf ../opencv2.framework
    mv "FRAMEWORK_BUILD_${ARCH_ARRAY[0]}/opencv2.framework" ..
    cd ..

    # Set up headers (from framework).
    # We deliberately COPY (not symlink) the headers out of the framework so
    # that include/opencv2/ is self-contained. The CI cache only stores
    # opencv/include and opencv/lib/$PLATFORM_DIR; symlinks into
    # ../opencv2.framework/Headers/ would dangle on cache restore because
    # the framework directory itself isn't cached, breaking the next build
    # with "fatal error: 'opencv2/core.hpp' file not found".
    # cp -RL follows symlinks (Headers itself is a symlink to
    # Versions/Current/Headers inside the framework bundle).
    rm -rf include/opencv2
    mkdir -p include/opencv2
    cp -RL opencv2.framework/Headers/* include/opencv2/

elif [ "$PLATFORM_DIR" = "windows" ]; then
    #
    # Windows build via CMake + Visual Studio 17 2022 generator.
    # The VS generator locates MSVC automatically — no vcvarsall.bat needed.
    #

    mkdir -p build_windows && cd build_windows

    # BUILD_WITH_STATIC_CRT=OFF is critical: OpenCV's CMake defaults to /MT
    # (static MSVCRT) on Windows, but Swift's clang and SPM-built C++ targets
    # use /MD (dynamic MSVCRT). Linking would fail with:
    #   lld-link: /failifmismatch: 'RuntimeLibrary'
    #   ... has value MD_DynamicRelease
    #   opencv2.lib(...) has value MT_StaticRelease
    # Forcing OFF tells OpenCV to compile with /MD, matching the rest of the
    # build.
    cmake .. \
        -G "Visual Studio 17 2022" \
        -A x64 \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_WITH_STATIC_CRT=OFF \
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
        -DWITH_WIN32UI=OFF \
        -DBUILD_ZLIB=ON \
        -DBUILD_PNG=ON \
        -DBUILD_TIFF=ON \
        -DBUILD_JPEG=ON

    cmake --build . --config Release --parallel "$(nproc)"

    # Merge all static libs into one using lib.exe (MSVC's librarian).
    # This is the Windows equivalent of the ar -M approach used on Linux.
    VSWHERE="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
    VS_WIN="$("$VSWHERE" -latest -products '*' \
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
        -property installationPath 2>/dev/null | tr -d '\r')"
    VS_BASH="$(cygpath -u "$VS_WIN")"
    VCTOOLS_VER=$(tr -d '\r\n' < "$VS_BASH/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt")
    LIB_EXE="$VS_BASH/VC/Tools/MSVC/$VCTOOLS_VER/bin/Hostx64/x64/lib.exe"

    OUTLIB="../../lib/$PLATFORM_DIR/opencv2.lib"
    mkdir -p "$(dirname "$OUTLIB")"

    # Collect all .lib files produced or referenced by the Release build.
    #
    # `lib/Release/` holds OpenCV's own modules. `3rdparty/lib/Release/`
    # holds the from-source 3rdparty deps that CMake builds (zlib, libpng,
    # libtiff, libjpeg-turbo, ittnotify, ipphal, ippiw).
    #
    # BUT the precompiled Intel IPPICV ships its own .lib in
    # `3rdparty/ippicv/ippicv_win/icv/lib/intel64/` (typically
    # `ippicvmt.lib`) — NOT under `3rdparty/lib/Release/`. If we don't
    # bundle it, the final star.exe link fails with undefined
    # `ippicvi*` symbols referenced by opencv2.lib(mean_ipp.obj),
    # since OpenCV's HAL uses IPPICV for inner loops on x86.
    #
    # Recurse the whole `3rdparty/` tree, excluding any */Debug/* paths
    # to keep debug variants out of the merged Release archive.
    #
    # Also exclude `*.dir/*` paths: CMake names per-target intermediate
    # output directories `<target>.dir/`, and libjpeg-turbo's build emits
    # sub-libraries `jpeg12-static.lib` and `jpeg16-static.lib` under
    # `3rdparty/libjpeg-turbo/jpeg{12,16}-static.dir/Release/` that are
    # *also* folded into the canonical `3rdparty/lib/Release/libjpeg-turbo.lib`.
    # Including the intermediates causes duplicate `jpeg12_*` / `jpeg16_*`
    # symbols in opencv2.lib and the final star.exe link fails under lld-link
    # (lib.exe only warns LNK4006 during the merge, but keeps the dup objects).
    ALL_LIBS=$(find lib/Release 3rdparty \
        -name '*.lib' \
        -not -path '*/Debug/*' \
        -not -path '*.dir/*' \
        2>/dev/null | sort -u)

    # lib.exe requires Windows-style paths.
    WIN_OUTLIB="$(cygpath -w "$(cd "$(dirname "$OUTLIB")" && pwd)/$(basename "$OUTLIB")")"
    LIB_ARGS=()
    for lib in $ALL_LIBS; do
        LIB_ARGS+=("$(cygpath -w "$(cd "$(dirname "$lib")" && pwd)/$(basename "$lib")")")
    done

    echo "==> Merging ${#LIB_ARGS[@]} .lib files into opencv2.lib..."
    "$LIB_EXE" /OUT:"$WIN_OUTLIB" "${LIB_ARGS[@]}"

    cd ../..  # back to opencv/

    # Set up headers (from source + generated, same as Linux).
    rm -rf include/opencv2
    mkdir -p include/opencv2

    cp opencv/build_windows/cvconfig.h include/opencv2/
    cp opencv/build_windows/opencv2/opencv_modules.hpp include/opencv2/

    for mod in core imgproc imgcodecs features2d calib3d flann highgui; do
        if [ -d "opencv/modules/$mod/include/opencv2" ]; then
            cp -r opencv/modules/$mod/include/opencv2/* include/opencv2/
        fi
    done

    if [ -f "opencv/include/opencv2/opencv.hpp" ]; then
        cp "opencv/include/opencv2/opencv.hpp" include/opencv2/
    else
        echo "WARNING: opencv/include/opencv2/opencv.hpp not found — umbrella header missing"
    fi

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

    # Merge all static libs into one using ar MRI scripted operations.
    # ADDLIB copies each archive's members preserving their internal
    # member-path names (e.g. CMakeFiles/opencv_core.dir/src/alloc.cpp.o),
    # so two archives containing a file named alloc.cpp.o get distinct
    # member entries and neither silently overwrites the other.
    # (The older ar x + ar qc approach stripped paths to basenames, causing
    # exactly this kind of silent collision.)
    OUTLIB="../../lib/$PLATFORM_DIR/libopencv2.a"
    rm -f "$OUTLIB"
    {
        echo "CREATE $OUTLIB"
        for lib in $ALL_LIBS; do
            echo "ADDLIB $lib"
        done
        echo "SAVE"
        echo "END"
    } | ar -M
    ranlib "$OUTLIB"

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

    # copy the umbrella opencv.hpp from the source tree
    # (it lives in opencv/include/opencv2/, not in any per-module directory)
    if [ -f "opencv/include/opencv2/opencv.hpp" ]; then
        cp "opencv/include/opencv2/opencv.hpp" include/opencv2/
    else
        echo "WARNING: opencv/include/opencv2/opencv.hpp not found — umbrella header missing"
    fi
fi
