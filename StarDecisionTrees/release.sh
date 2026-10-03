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

# Ask swift build, given the same configuration and arch flags as a build,
# where it put the products rather than assume a layout, and set BIN_PATH to
# that directory and MODULE_PATH to the StarDecisionTrees.swiftmodule in it.
# The native build system uses .build/<triple>/release and keeps modules in a
# Modules/ subdirectory.  xcbuild (which older toolchains use to build more
# than one arch) and swiftbuild (the default from Swift 6.4) put the module
# beside the lib, in .build/apple/Products/Release and
# .build/out/Products/Release respectively.
find_products() {
    BIN_PATH=$(swift build "$@" --show-bin-path)
    BIN_PATH=${BIN_PATH%$'\r'}  # in case swift.exe ends its output with \r\n
    MODULE_PATH=$BIN_PATH/Modules/StarDecisionTrees.swiftmodule
    [ -e "$MODULE_PATH" ] || MODULE_PATH=$BIN_PATH/StarDecisionTrees.swiftmodule
}

if [ "$PLATFORM" = "Darwin" ]; then
    # macOS: build universal binary (x86_64 + arm64)

    # this produces the swift module for both arches (which we need).
    # swiftbuild makes a universal .a here too, but xcbuild only leaves
    # a .o file beside the module, which is useless
    swift build --configuration release -Xswiftc -O  --arch x86_64 --arch arm64

    find_products --configuration release --arch x86_64 --arch arm64
    mv "$MODULE_PATH" include/release/$PLATFORM_DIR

    # use swiftbuild's universal .a if there is one (checking one arch per
    # -verify_arch: Xcode 27's lipo rejects a list of them)
    UNIVERSAL_LIB=$BIN_PATH/libStarDecisionTrees.a
    if [ -f "$UNIVERSAL_LIB" ] &&
       lipo "$UNIVERSAL_LIB" -verify_arch x86_64 &&
       lipo "$UNIVERSAL_LIB" -verify_arch arm64; then
        mv "$UNIVERSAL_LIB" lib/release/$PLATFORM_DIR
    else
        # build the real .a file, one arch at a time, moving each one out
        # as soon as it is built in case both builds use the same directory
        for ARCH in x86_64 arm64; do
            swift build --configuration release -Xswiftc -O --arch $ARCH
            find_products --configuration release --arch $ARCH
            mv "$BIN_PATH/libStarDecisionTrees.a" .build/libStarDecisionTrees-$ARCH.a
        done

        # then lipo them together
        lipo .build/libStarDecisionTrees-arm64.a \
             .build/libStarDecisionTrees-x86_64.a \
              -create -output lib/release/$PLATFORM_DIR/libStarDecisionTrees.a
    fi

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
    find_products --configuration release
    if [ -f "$BIN_PATH/libStarDecisionTrees.a" ]; then
        mv "$BIN_PATH/libStarDecisionTrees.a" \
           lib/release/$PLATFORM_DIR/StarDecisionTrees.lib
    elif [ -f "$BIN_PATH/StarDecisionTrees.lib" ]; then
        # Fallback: older Swift / a future toolchain might emit a true .lib.
        mv "$BIN_PATH/StarDecisionTrees.lib" lib/release/$PLATFORM_DIR/
    else
        echo "ERROR: no StarDecisionTrees static archive found in $BIN_PATH" >&2
        ls -la "$BIN_PATH" >&2 || true
        exit 1
    fi
    mv "$MODULE_PATH" include/release/$PLATFORM_DIR/

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

    find_products --configuration release
    mv "$BIN_PATH/libStarDecisionTrees.a" lib/release/$PLATFORM_DIR
    mv "$MODULE_PATH" include/release/$PLATFORM_DIR
fi
