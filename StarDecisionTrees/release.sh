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
    # Bypass the integrated Swift driver — required on Swift 6.0 + Windows.
    #
    # Symptom we hit on every run of StarCore (transitively built here):
    #     [29/31] Compiling StarCore AbstractBlobProcessor.swift
    #     <unknown>:0: error: supplementary output file map
    #     'C:\…\TemporaryDirectory.XXXXX\supplementaryOutputs-1' is missing
    #     an entry for '…\StarCore\Sources\StarCore\AbstractBlobProcessor.swift'
    #     (this likely indicates a compiler issue …)
    #
    # The "supplementary output file map" is a JSON file the *integrated*
    # swift-driver writes per swiftc invocation, mapping each primary input
    # file to its supplementary outputs (.swiftmodule, .swiftdoc, .o, …).
    # On Swift 6.0 / windows-2022, the driver's indexing of which batch a
    # file belongs to gets out of sync with which "supplementaryOutputs-N"
    # file is consulted, and it aborts with the message above.
    #
    # The bug is fully deterministic — same file every run — and is NOT a
    # parallelism race. We confirmed by reproducing it with:
    #   - -Xswiftc -disable-batch-mode (no batch grouping)
    #   - -Xswiftc -wmo                (one swiftc call per module)
    #   - -j 1                         (one SPM job at a time)
    # All three insufficient: the integrated driver still emits the broken
    # map regardless.
    #
    # The classic (non-integrated) Swift driver doesn't use these map files
    # at all — it passes outputs on the command line — so falling back to
    # it sidesteps the bug entirely. We disable the integrated driver via
    # SPM's --no-use-integrated-swift-driver. Slightly slower (extra
    # process per invocation) but completes correctly. Drop this once
    # Swift on Windows past 6.0 is usable here (currently blocked by
    # Swift 6.1's installer not setting up the MSVC env in a way OpenCV's
    # CMake can auto-detect).
    #
    # MEM_PER_JOB_GB still informs the job cap; we keep -j ≥ 1 here since
    # the underlying race never reproduced with the integrated driver off.
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
    echo "==> swift build -j $JOBS  (${NCPU} CPUs, memory-limited; trying integrated-driver env vars)"

    # NOTE: --no-use-integrated-swift-driver is NOT a valid SPM 6.0 flag —
    # only the positive --use-integrated-swift-driver exists, and there's no
    # CLI way to turn the integrated driver off. The env vars below are the
    # only documented switch. Setting both names because the variable spelling
    # has drifted between SPM versions. May or may not actually fix the
    # supplementary-output-map bug (the underlying swift-driver is the same
    # code in either mode), but it's the only knob left short of patching
    # source. If this run also fails on AbstractBlobProcessor.swift the
    # conclusion is the bug isn't reachable from build-config flags at all
    # and we'll have to fix it by changing the StarCore module layout.
    export SWIFTPM_USE_INTEGRATED_DRIVER=0
    export SWIFTPM_DISABLE_INTEGRATED_DRIVER=1

    swift build --configuration release -Xswiftc -O -j "$JOBS"

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
