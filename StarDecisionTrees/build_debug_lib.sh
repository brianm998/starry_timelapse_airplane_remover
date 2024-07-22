# re-build the categorizers as static .a files to avoid recompiling them
# similar to release.sh, however builds on one arch and in debug mode, but still speed optimized

set -e

# clean previous builds
rm -rf .build
rm -rf lib/debug
rm -rf include/debug

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

# build without optimization, for the current arch only
swift build --arch `uname -m` -Xswiftc -O

# create output dirs
mkdir -p lib/debug
mkdir -p include/debug

# copy output dylib and swiftmodule to output dirs
mv .build/debug/libStarDecisionTrees.a lib/debug
mv .build/debug/StarDecisionTrees.swiftmodule include/debug

