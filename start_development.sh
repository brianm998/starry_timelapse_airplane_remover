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

# build opencv2 for the active arch only
cd opencv
./build.sh
cd ..

# build StarDecisionTrees for the active arch only
cd StarDecisionTrees
./build_debug_lib.sh
cd ..
