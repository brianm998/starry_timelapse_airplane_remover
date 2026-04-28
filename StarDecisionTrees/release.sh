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
    Darwin) PLATFORM_DIR="macos" ;;
    Linux)  PLATFORM_DIR="linux" ;;
    *)      echo "Unsupported platform: $PLATFORM"; exit 1 ;;
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
