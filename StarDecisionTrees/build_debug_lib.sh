# re-build the categorizers as static .a files to avoid recompiling them
# similar to release.sh, however builds on one arch and in debug mode, but still speed optimized

# clean previous builds
rm -rf .build

# generate current list of all decision trees in StarDecisionTrees.swift
./makeList.pl

# first run after cleaning build file dies on error about missing objc bridging header for semaphore
# re - run it without deleting the build file, and it works.

# build for current arch (development)
swift build || swift build --arch `uname -m` -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O

# can't properly build against this with these still here
rm -rf .build/debug/*.build

