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
    # Windows: single architecture build, forced to one job at a time.
    #
    # Why -j 1 + -Xswiftc -wmo together:
    #   Swift 6.0 on Windows has a swift-driver race when multiple swiftc
    #   invocations are running in parallel — each writes its own
    #   "supplementaryOutputs-N" JSON file to a shared temp directory, and
    #   the driver occasionally finalises that map with an entry missing,
    #   then aborts:
    #       <unknown>:0: error: supplementary output file map
    #       '…\supplementaryOutputs-N' is missing an entry for '…file.swift'
    #       (this likely indicates a compiler issue …)
    #   We hit this reproducibly on StarCore/AbstractBlobProcessor.swift on
    #   windows-2022 with -j 4. Tried, insufficient:
    #     - -Xswiftc -disable-batch-mode (still concurrent invocations)
    #     - -Xswiftc -wmo alone           (still concurrent invocations)
    #   What actually works: pin SPM to a single concurrent job (-j 1) so
    #   there are no parallel writers to the supplementary output map at
    #   all, AND keep -wmo so each module compiles as one swiftc call (no
    #   intra-invocation multi-primary batches either). Slower, but the
    #   only configuration we've seen complete on Swift 6.0 + windows-2022.
    #   Once we can upgrade Swift on Windows past 6.0 (currently blocked
    #   because Swift 6.1's installer no longer sets up the MSVC env in a
    #   way OpenCV's CMake auto-detects), this can come off.
    #
    # MEM_PER_JOB_GB stays informational — even with -j 1 we leave the
    # memory probe in place so future maintainers can see why the cap is
    # what it is if/when the driver bug is fixed.
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
    JOBS=1
    echo "==> swift build -j $JOBS  (${NCPU} CPUs available, capped at 1 to avoid swift-driver supplementary output map race; ${AVAIL_MEM_GB:-?} GB RAM)"

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
