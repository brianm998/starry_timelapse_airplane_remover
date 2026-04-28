# re-build the categorizers as static .a files to avoid recompiling them
# similar to release.sh, however builds on one arch and in debug mode, but still speed optimized

set -e

# detect platform
PLATFORM="$(uname -s)"
case "$PLATFORM" in
    Darwin) PLATFORM_DIR="macos" ;;
    Linux)  PLATFORM_DIR="linux" ;;
    *)      echo "Unsupported platform: $PLATFORM"; exit 1 ;;
esac

# clean previous builds
rm -rf .build
rm -rf lib/debug/$PLATFORM_DIR
rm -rf include/debug/$PLATFORM_DIR

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

# Compute a job count that won't exhaust RAM.
# Large decision-tree Swift files use ~2 GB each, so cap jobs at
# floor(available_mem_GB / 2), but never exceed the CPU count.
MEM_PER_JOB_GB=2
if [ "$PLATFORM" = "Darwin" ]; then
    NCPU=$(sysctl -n hw.logicalcpu)
    TOTAL_MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
    MEM_JOBS=$(( TOTAL_MEM_GB / MEM_PER_JOB_GB ))
else
    NCPU=$(nproc)
    # MemAvailable: free + reclaimable memory (does not trigger swap)
    AVAIL_MEM_GB=$(awk '/MemAvailable/ { print int($2/1024/1024) }' /proc/meminfo)
    MEM_JOBS=$(( AVAIL_MEM_GB / MEM_PER_JOB_GB ))
fi
JOBS=$(( MEM_JOBS < NCPU ? MEM_JOBS : NCPU ))
[ "$JOBS" -lt 1 ] && JOBS=1
echo "==> swift build -j $JOBS  (${NCPU} CPUs, memory-limited)"

# build without optimization, for the current arch only
swift build -j "$JOBS" --arch `uname -m`

# create output dirs
mkdir -p lib/debug/$PLATFORM_DIR
mkdir -p include/debug/$PLATFORM_DIR

# copy output lib and swiftmodule to platform-specific output dirs
mv .build/debug/libStarDecisionTrees.a lib/debug/$PLATFORM_DIR
mv .build/debug/Modules/StarDecisionTrees.swiftmodule include/debug/$PLATFORM_DIR
