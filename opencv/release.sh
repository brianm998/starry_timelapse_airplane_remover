#!/bin/bash

# this script builds opencv2 for release builds
#
# On macOS: builds for all current apple architectures (universal binary)
# On Linux: builds for the current architecture

set -e

PLATFORM="$(uname -s)"

if [ "$PLATFORM" = "Darwin" ]; then
    # for release builds we build for all platforms
    export ARCHS="x86_64,arm64"
fi

./build.sh
