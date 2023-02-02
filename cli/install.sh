# build and install a release build for the arch we're running on into /usr/local/bin
# also copy the perl wrapper for ffmpeg usage
swift build --configuration release --arch `uname -m`
sudo cp .build/`uname -m`-apple-macosx/release/ntar /usr/local/bin
sudo cp ntar.pl /usr/local/bin
