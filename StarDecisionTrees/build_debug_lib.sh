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

# build without optimization, for the current arch only
swift build -j 10 --arch `uname -m`

# create output dirs
mkdir -p lib/debug/$PLATFORM_DIR
mkdir -p include/debug/$PLATFORM_DIR

# copy output lib and swiftmodule to platform-specific output dirs
mv .build/debug/libStarDecisionTrees.a lib/debug/$PLATFORM_DIR
mv .build/debug/Modules/StarDecisionTrees.swiftmodule include/debug/$PLATFORM_DIR
