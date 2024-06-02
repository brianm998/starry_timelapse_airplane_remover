#!/bin/bash

# this script produces a new release of star
#
# created are a zip file in releases/ and local and remote release tags

set -e

####
# first build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into the gui, cli and decision tree generator apps
####
cd StarDecisionTrees
./release.sh
cd ..

# result ends up here:
# StarDecisionTrees/libStarDecisionTrees.a

####
# next build a universal (all arch) binary for the cli     
####
cd cli
./release.sh
cd ..

# result ends up here:
# cli/.build/star_cli_${STAR_VERSION}.pkg"


####
# next build a .app dir from the gui
####
cd gui
./release.sh
cd ..

# results end up here:
# gui/.build/star_app_${STAR_VERSION}.pkg"


####
# move the gui and cli apps into releases dir and tag git local and remote
####

./finishRelease.sh

# output should be in releases/star-${STAR_VERSION}.zip
# tag release/${STAR_VERSION} should be on both local and remote
