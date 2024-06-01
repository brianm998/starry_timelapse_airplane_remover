# re-build the categorizers as static .a files to avoid recompiling them

# clean previous builds
rm -rf .build

# first run after cleaning build file dies on error about missing objc bridging header for semaphore
# re - run it without deleting the build file, and it works.

# this one will fail
swift build --arch `uname -m` -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O

# this one should work
# build for current arch (development)
swift build --arch `uname -m` -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static -Xswiftc -O

# can't properly build against this with these still here
rm -rf .build/debug/*.build
