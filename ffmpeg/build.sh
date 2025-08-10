#!/bin/bash
set -e

# Ensure NASM installed (Homebrew)
if ! command -v nasm &>/dev/null; then
  echo "Installing nasm via Homebrew..."
  brew install nasm
fi

# Explicitly set Apple tools to avoid MacPorts conflicts
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$PATH"
export CC=clang
export CXX=clang++
export AR=/usr/bin/ar
export RANLIB=/usr/bin/ranlib
export NASM=$(which nasm)
export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:/usr/lib/pkgconfig

# Optional: set target architectures for universal binary
ARCHS="x86_64 arm64"
MIN_SDK_VERSION="11.0"

# Configure flags: tweak these as needed
CONFIGURE_FLAGS=(
  --prefix="$PWD/ffmpeg-build"
  --enable-gpl
  --enable-nonfree
  --enable-libx264
  --enable-libx265
  --enable-libvpx
  --enable-libfdk-aac
  --enable-libmp3lame
  --enable-libopus
  --enable-libass
  --enable-libfreetype
  --enable-shared
  --disable-static
)

echo "Starting FFmpeg configure..."
./configure "${CONFIGURE_FLAGS[@]}" \
  --arch="$ARCHS" \
  --extra-cflags="-mmacosx-version-min=$MIN_SDK_VERSION" \
  --extra-ldflags="-mmacosx-version-min=$MIN_SDK_VERSION" \
  --extra-cflags="-I$(brew --prefix fdk-aac)/include" \
  --extra-ldflags="-L$(brew --prefix fdk-aac)/lib" 

echo "Running make clean..."
make clean

echo "Building FFmpeg..."
make -j$(sysctl -n hw.ncpu)

echo "Installing FFmpeg..."
make install

echo "Build complete. FFmpeg installed at $PWD/ffmpeg-build"
