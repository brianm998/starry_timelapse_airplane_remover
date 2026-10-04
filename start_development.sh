#!/bin/bash

#
# Run this script to start Star development.
#
# It builds two static libraries that are used by Star:
#   - opencv
#   - StarDecisionTrees
# and the ffmpeg and ffprobe that video import and export run, which are built, not
# committed, into external_binaries/bin (see ffmpeg/README.md).
#
# Star development is not possible without these built locally.
# Only the active architecture is built for here, i.e. arm vs x86.
# Use the release.sh script for a universal build.
#

set -e

# Star also needs Eigen from the system, and (for the gui) its bundled video;
# neither is built here, and a missing one only shows up much later in a Star
# build, so say so now rather than after the libraries below.  The release
# StarDecisionTrees that gui/local_release.sh needs is not checked: this script
# builds the debug one, which is what a development build links.
source "$(dirname "$0")/preflight.sh"
preflight_eigen
if [ "$(uname -s)" = "Darwin" ]; then
    preflight_gui_videos
fi
# the tools for the ffmpeg build below, but only if that build will actually run
if [ ! -x external_binaries/bin/ffmpeg ] || [ ! -x external_binaries/bin/ffprobe ]; then
    preflight_ffmpeg_tools
fi
preflight_finish

# build opencv2 for the active arch only
cd opencv
./build.sh
cd ..

# build StarDecisionTrees for the active arch only
cd StarDecisionTrees
./build_debug_lib.sh
cd ..

# build ffmpeg and ffprobe for the active arch only, unless they are already here and run
# on this machine.  Install them where the Xcode project, StarCore's tests and the desktop
# app's gradle staging all look: external_binaries/bin.
if [ -x external_binaries/bin/ffmpeg ] && [ -x external_binaries/bin/ffprobe ] \
   && external_binaries/bin/ffmpeg -hide_banner -version >/dev/null 2>&1; then
    echo "==> ffmpeg: already built, skipping"
else
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)             FFMPEG_TARGET=macos-arm64 ;;
        Darwin-x86_64)            FFMPEG_TARGET=macos-x64 ;;
        Linux-x86_64)             FFMPEG_TARGET=linux-x64 ;;
        Linux-aarch64)            FFMPEG_TARGET=linux-arm64 ;;
        MINGW*-x86_64|MSYS*-x86_64) FFMPEG_TARGET=windows-x64 ;;
        *) echo "no ffmpeg build for $(uname -s)-$(uname -m)" >&2; exit 1 ;;
    esac
    ./ffmpeg/build.sh --install "$FFMPEG_TARGET"
fi
