# build for x86 and arm
swift build --configuration release --arch arm64 --arch x86_64
7za a .build/ntar.7z .build/apple/Products/Release/ntar
