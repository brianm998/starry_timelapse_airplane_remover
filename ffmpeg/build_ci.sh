#!/bin/bash
# Builds static ffmpeg + ffprobe from source for Linux and Windows (MSYS2 MINGW64), for bundling
# into the Star desktop installers. macOS keeps the hand-built binaries in external_binaries/bin
# (see build.sh, which builds shared libs and isn't suitable for bundling).
#
# Usage: ffmpeg/build_ci.sh <output-dir>      (run from anywhere; clones FFmpeg into a temp dir)
#
# GPL build with the codecs StarCore's encoder list exposes on non-Apple platforms (x264/x265/vpx),
# plus mp3lame/opus. No --enable-nonfree / fdk-aac: the result is redistributable.
set -euo pipefail

OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
FFMPEG_TAG="${FFMPEG_TAG:-n7.1.1}"
WORK="$(mktemp -d)"
cd "$WORK"

git clone --depth 1 --branch "$FFMPEG_TAG" https://github.com/FFmpeg/FFmpeg.git src
cd src

EXTRA=()
case "$(uname -s)" in
  MINGW*|MSYS*) EXTE=".exe"; EXTRA+=(--target-os=mingw32 --arch=x86_64) ;;
  *)            EXTE="";     EXTRA+=(--disable-network) ;;  # fully static glibc can't resolve hostnames anyway
esac

./configure \
  --prefix="$WORK/install" \
  --enable-gpl \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libmp3lame --enable-libopus \
  --disable-shared --enable-static \
  --disable-doc --disable-ffplay \
  --pkg-config-flags=--static \
  --extra-ldflags="-static" \
  "${EXTRA[@]}" || { tail -50 ffbuild/config.log; exit 1; }

make -j"$(nproc)"

strip "ffmpeg$EXTE" "ffprobe$EXTE" || true
cp "ffmpeg$EXTE" "ffprobe$EXTE" "$OUT/"

# Fail the build rather than ship a binary that can't encode what the app offers.
"$OUT/ffmpeg$EXTE" -hide_banner -encoders | grep -E "libx264|libx265|libvpx" 
"$OUT/ffprobe$EXTE" -version | head -1
