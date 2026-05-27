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
    # Windows: single architecture build.
    # Same memory-aware job cap as Linux; query available RAM via PowerShell
    # since /proc/meminfo does not exist on Windows.
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

    # -Xswiftc -wmo (whole-module-optimization):
    #   Workaround for a Swift 6.0 Windows driver bug. When the driver groups
    #   multiple .swift files into a single swiftc invocation, it sometimes
    #   emits a supplementary output file map missing an entry, then fails:
    #       <unknown>:0: error: supplementary output file map
    #       '…\supplementaryOutputs-N' is missing an entry for '…file.swift'
    #   This reproduces consistently while StarDecisionTrees is building its
    #   StarCore dependency on windows-2022 + Swift 6.0. -wmo collapses each
    #   module into a single compile unit so the supplementary output file
    #   map can't fragment, sidestepping the driver bug entirely. Note this
    #   must be set HERE (not just in release_windows.sh) because SPM
    #   recursively rebuilds dependencies, and the failure happens during
    #   the dependency build, never reaching the CLI build step.
    swift build --configuration release -Xswiftc -O -Xswiftc -wmo -j "$JOBS"

    # SPM on Windows produces TargetName.lib (no "lib" prefix, COFF archive).
    mv .build/release/StarDecisionTrees.lib lib/release/$PLATFORM_DIR/
    mv .build/release/Modules/StarDecisionTrees.swiftmodule include/release/$PLATFORM_DIR/

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
