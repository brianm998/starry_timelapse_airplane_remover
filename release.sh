#!/bin/bash

# this script produces a new release of star
#
# created are a zip file in releases/ and local and remote release tags

set -e

####
# first build opencv2 into a static, universal library (.a file)
# this is a large c++ library that is used by the kernel hough transform 
####

# doesn't properly build for all archs on i86 :(
#cd opencv
#./release.sh
#cd ..

# results end up here:
# opencv/lib
# opencv/include

####
# next build the decision tree code into a static, universal library (.a file)
# this can be large, and is linked into the gui, cli and decision tree generator apps
####
cd StarDecisionTrees
./release.sh
cd ..

# results end up here:
# StarDecisionTrees/lib
# StarDecisionTrees/include

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
