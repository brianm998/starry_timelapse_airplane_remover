#!/bin/bash
# Builds the kernel differential harnesses next to this script: ./build.sh [-O2|-O3|-Os|...] [extra clang flags]
# e.g.  ./build.sh -O2 && ./median_bench sweep 3000 && ./warp_bench sweep 2000 && ./akaze_bench 90
# Add -fsanitize=address,undefined for the sanitiser run.
# Needs the opencv/ symlinks a worktree build needs (see CLAUDE.md of the checkout) and Eigen, as the package does.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OPT=${1:--O2}; shift || true
ARCH=${ARCH:-$(uname -m)}
FLAGS="-std=c++2b $OPT -DNDEBUG -arch $ARCH $* -I $ROOT/opencv/include -I $ROOT/opencv/include/opencv2 \
  -I $ROOT/StarCpp/Sources/StarCpp -I $ROOT/StarCpp/Sources/StarCpp/include -I $ROOT/StarCpp/Sources/kht/include \
  -I /opt/homebrew/include/eigen3 -I /usr/local/include/eigen3"
LIBS="$ROOT/opencv/lib/macos/libopencv2.a -framework Accelerate -framework OpenCL -framework CoreFoundation -framework CoreGraphics -framework Foundation -lz"
cd "$HERE"
xcrun clang++ $FLAGS median_bench.cpp -o median_bench $LIBS
xcrun clang++ $FLAGS warp_bench.cpp   -o warp_bench   $LIBS
# AKAZEDetector.cpp is included whole, so this one links the few files it needs
S=$ROOT/StarCpp/Sources/StarCpp
xcrun clang++ $FLAGS akaze_bench.cpp $S/starcpp_bridge_logging.cpp $S/MatWrapper.cpp $S/ImageCache_C.cpp $S/OCVFeatureSet.cpp $S/GPUOps_C.cpp -o akaze_bench $LIBS
