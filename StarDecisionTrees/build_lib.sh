# re-build the categorizers as static .a files to avoid recompiling them

# clean previous builds
rm -rf .build

# build for current arch (development)
swift build --arch `uname -m` -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
