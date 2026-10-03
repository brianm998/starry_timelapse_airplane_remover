#!/bin/bash

#
# Run this script to start Star development.
#
# It builds two static libraries that are used by Star:
#   - opencv
#   - StarDecisionTrees
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
preflight_finish

# build opencv2 for the active arch only
cd opencv
./build.sh
cd ..

# build StarDecisionTrees for the active arch only
cd StarDecisionTrees
./build_debug_lib.sh
cd ..
