rm -rf .build
swift build -Xswiftc -emit-module -Xswiftc -emit-library -Xswiftc -static
