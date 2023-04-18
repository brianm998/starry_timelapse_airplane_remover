# re-build the categorizers as static .a files to avoid recompiling them

# clean previous builds
rm -rf .build

# build for x86
swift build --arch x86_64 -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
mv *.a .build/x86_64-apple-macosx

# build for arm64
swift build --arch arm64  -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
mv *.a .build/arm64-apple-macosx

# lipo them together into a universal .a file for both archs
lipo .build/arm64-apple-macosx/libNtarDecisionTrees.a \
     .build/x86_64-apple-macosx/libNtarDecisionTrees.a \
     -create -output libNtarDecisionTrees.a
