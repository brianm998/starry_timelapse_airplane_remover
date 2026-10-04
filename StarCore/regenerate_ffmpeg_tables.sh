#!/bin/bash
#
# Regenerates the three tables StarCore describes ffmpeg with:
#
#   Sources/StarCore/FFmpegCodec.swift        FFmpegCodec and FFmpegEncoder: every codec, its
#                                             encoders, and the pixel formats each encoder takes
#   Sources/StarCore/FFmpegPixelFormat.swift  FFmpegPixelFormat
#   Sources/StarCore/FFmpegMuxer.swift        FFmpegMuxer: every container, and the encoders
#                                             each can hold
#
# They are generated from FFmpeg itself, so they have to be regenerated when ffmpeg/versions.env
# moves to a new FFmpeg, or a codec library is added or dropped: the Render Video dialog offers
# exactly what these list.  All three come from one build, because the muxer table names
# encoders and every encoder it names has to be a case in the codec table.
#
# What the build is:
#   - the same FFmpeg and codec libraries ffmpeg/build.sh ships, for this machine's
#     architecture ("tables" target), plus AMD's AMF encoders, which compile on any host;
#   - plus the encoders in ffmpeg_extra_encoders.txt, which cannot be built on a Mac at all
#     (NVIDIA NVENC).
# GPU encoders the dialog cannot drive yet (VAAPI, Quick Sync, Media Foundation: each needs a
# device or an option star does not pass) are left out of the tables.
#
# The result is deterministic: a second run changes nothing, so a diff after a version bump is
# the real change.
#
#   ./regenerate_ffmpeg_tables.sh [--work DIR]
#
# Needs what ffmpeg/build.sh needs (on a Mac: brew install nasm pkgconf meson ninja cmake) and
# a C compiler.  It is a Mac's tables on purpose: they list what exists, and which of it a given
# machine can use is decided when the dialog opens (FFmpegCapabilities).
#

set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"
WORK="$REPO_ROOT/ffmpeg/.work"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --work) WORK="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)  TARGET=macos-arm64 ;;
    Darwin-x86_64) TARGET=macos-x64 ;;
    *) echo "tables are generated on a Mac" >&2; exit 1 ;;
esac

# the tables variant of ffmpeg/build.sh (cheap when its dependencies are already built)
"$REPO_ROOT/ffmpeg/build.sh" --work "$WORK" tables

DEPS="$WORK/$TARGET/prefix"
TABLES="$WORK/$TARGET/prefix-tables"
export FFMPEG="$TABLES/bin/ffmpeg"
export EXTRA_ENCODERS="$PWD/ffmpeg_extra_encoders.txt"
[ -x "$FFMPEG" ] || { echo "no ffmpeg at $FFMPEG" >&2; exit 1; }

echo "==> $("$FFMPEG" -hide_banner -version | head -n 1)"

echo "==> FFmpegCodec.swift"
perl write_ffmpeg_codec_swift.pl

echo "==> FFmpegPixelFormat.swift"
perl write_ffmpeg_pixel_format_swift.pl

echo "==> FFmpegMuxer.swift"
# libavformat's static libraries and their dependencies, found through the .pc files this
# build installed
export PKG_CONFIG_LIBDIR="$TABLES/lib/pkgconfig:$DEPS/lib/pkgconfig"
PKG_CONFIG="$(command -v pkg-config || command -v pkgconf)"
TOOL="$(mktemp -d)/muxer_codecs"
# shellcheck disable=SC2046
cc "$REPO_ROOT/ffmpeg/muxer_codecs.c" -o "$TOOL" \
    $("$PKG_CONFIG" --static --cflags --libs libavformat libavcodec libavutil)
"$TOOL" "$EXTRA_ENCODERS" > Sources/StarCore/FFmpegMuxer.swift
rm -rf "$(dirname "$TOOL")"

echo "==> done; the table sizes:"
wc -l Sources/StarCore/FFmpegCodec.swift Sources/StarCore/FFmpegPixelFormat.swift Sources/StarCore/FFmpegMuxer.swift
