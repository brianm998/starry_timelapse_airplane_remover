# build x86 and arm into a single universal binary
swift build --configuration release --arch arm64 --arch x86_64
# 7zip it up because it's huge
7za a .build/ntar.7z .build/apple/Products/Release/ntar
