#!/bin/bash

set -e

####
# build the decision tree code into a static library (.a file)
# this can be large, and is linked into the gui and cli apps, as into the
# decision tree generator.  It can take hours to build a large set of trees,
# due to a number of factors:
#  - decision trees are REALLY big swift files
#  - compling with optimization on is slow
#
# On macOS: builds a universal binary (x86_64 + arm64) via lipo.
# On Linux: builds a single-architecture .a for the current arch.
####

# detect platform
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin)    PLATFORM_DIR="macos" ;;
    Linux)     PLATFORM_DIR="linux" ;;
    MINGW*|MSYS_NT*) PLATFORM_DIR="windows" ;;
    *)         echo "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

# clear out any previous build
rm -rf .build
rm -rf lib/release/$PLATFORM_DIR
rm -rf include/release/$PLATFORM_DIR

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

# create output dirs
mkdir -p lib/release/$PLATFORM_DIR
mkdir -p include/release/$PLATFORM_DIR

if [ "$PLATFORM" = "Darwin" ]; then
    # macOS: build universal binary (x86_64 + arm64)

    # this only produces the swift module for both arches (which we need),
    # and a .o file, which is useless
    swift build --configuration release -Xswiftc -O  --arch x86_64 --arch arm64

    mv .build/apple/Products/Release/StarDecisionTrees.swiftmodule include/release/$PLATFORM_DIR

    # build the real .a file

    # first for x86
    swift build --configuration release -Xswiftc -O --arch x86_64

    # next for arm
    swift build --configuration release -Xswiftc -O --arch arm64

    # then lipo them together
    lipo .build/arm64-apple-macosx/release/libStarDecisionTrees.a \
         .build/x86_64-apple-macosx/release/libStarDecisionTrees.a \
          -create -output lib/release/$PLATFORM_DIR/libStarDecisionTrees.a

elif [ "$PLATFORM_DIR" = "windows" ]; then
    # Windows: single architecture build. Same memory-aware job cap as
    # Linux; query available RAM via PowerShell since /proc/meminfo does
    # not exist on Windows.
    MEM_PER_JOB_GB=2
    NCPU=$(nproc)
    AVAIL_MEM_KB=$(powershell.exe -Command \
        "(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory" \
        2>/dev/null | tr -d '\r\n')
    if [ -n "$AVAIL_MEM_KB" ] && [ "$AVAIL_MEM_KB" -gt 0 ] 2>/dev/null; then
        AVAIL_MEM_GB=$(( AVAIL_MEM_KB / 1048576 ))
    else
        AVAIL_MEM_GB=4  # conservative fallback if PowerShell query fails
    fi
    MEM_JOBS=$(( AVAIL_MEM_GB / MEM_PER_JOB_GB ))
    JOBS=$(( MEM_JOBS < NCPU ? MEM_JOBS : NCPU ))
    [ "$JOBS" -lt 1 ] && JOBS=1
    echo "==> swift build -j $JOBS  (${NCPU} CPUs, memory-limited)"

    swift build --configuration release -Xswiftc -O -j "$JOBS"

    # Swift 6.1 on Windows actually produces libStarDecisionTrees.a (GNU ar
    # archive with "lib" prefix) under the triple-qualified build directory,
    # mirroring Linux. The earlier comment claimed SPM emitted a COFF-format
    # StarDecisionTrees.lib in .build/release/ — that is no longer true (and
    # may never have been; .build/release on Windows isn't guaranteed to be
    # a junction to the triple dir under Git Bash).
    #
    # cli/Package.swift and release_windows.sh both reference the path
    # StarDecisionTrees.lib, so we rename .a -> .lib at the destination.
    # clang/lld on Windows accepts the GNU ar archive regardless of the
    # filename extension, since the cli passes the full path via -Xlinker.
    BUILD_DIR=.build/x86_64-unknown-windows-msvc/release
    if [ -f "$BUILD_DIR/libStarDecisionTrees.a" ]; then
        mv "$BUILD_DIR/libStarDecisionTrees.a" \
           lib/release/$PLATFORM_DIR/StarDecisionTrees.lib
    elif [ -f "$BUILD_DIR/StarDecisionTrees.lib" ]; then
        # Fallback: older Swift / a future toolchain might emit a true .lib.
        mv "$BUILD_DIR/StarDecisionTrees.lib" lib/release/$PLATFORM_DIR/
    else
        echo "ERROR: no StarDecisionTrees static archive found in $BUILD_DIR" >&2
        ls -la "$BUILD_DIR" >&2 || true
        exit 1
    fi
    mv "$BUILD_DIR/Modules/StarDecisionTrees.swiftmodule" \
       include/release/$PLATFORM_DIR/

else
    # Linux: single architecture build.
    # Decision-tree Swift files are very large; cap parallelism so each job
    # has ~2 GB of available RAM to avoid swap thrash.
    MEM_PER_JOB_GB=2
    NCPU=$(nproc)
    AVAIL_MEM_GB=$(awk '/MemAvailable/ { print int($2/1024/1024) }' /proc/meminfo)
    MEM_JOBS=$(( AVAIL_MEM_GB / MEM_PER_JOB_GB ))
    JOBS=$(( MEM_JOBS < NCPU ? MEM_JOBS : NCPU ))
    [ "$JOBS" -lt 1 ] && JOBS=1
    echo "==> swift build -j $JOBS  (${NCPU} CPUs, memory-limited)"

    swift build --configuration release -Xswiftc -O -j "$JOBS"

    mv .build/release/libStarDecisionTrees.a lib/release/$PLATFORM_DIR
    mv .build/release/Modules/StarDecisionTrees.swiftmodule include/release/$PLATFORM_DIR
fi
