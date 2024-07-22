#!/bin/bash

# this script builds opencv2 for release builds, using all current apple architectures
#

set -e

# for release builds we build for all platforms
export ARCHS="x86_64,arm64"

./build.sh
