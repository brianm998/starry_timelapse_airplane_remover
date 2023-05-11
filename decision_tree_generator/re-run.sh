#!/bin/bash
# this re-generates all outlier values from groups (takes a long time)
# and then generates a set of trees based upon this
# and compiles them into a static library .a file
# then runs tests against them

set -e

if [ $# -eq 0 ]
then
    echo
    echo "Need to supply outlier value output name"
    echo "This name will be used to congregate outlier values"
    echo
    echo "usage: $0 unique-name-outlier-values"
    exit 1
fi

# re-generate the outlier values from the outlier groups themselves
./regen_outlier_values.pl

# condense the csv files into a single spot
./condense_outlier_csv_files.pl /qp/ntar_validated/$1

# split them for test/train
./outlier_csv_split.pl /qp/ntar_validated/$1

# build trees
.build/debug/decision_tree_generator --forest 16 --no-prune -n 28 -t /qp/ntar_validated/$1-test /qp/ntar_validated/$1-train
#.build/debug/decision_tree_generator --forest 12 --no-prune -n 28 -t /qp/ntar_validated/$1-test /qp/ntar_validated/$1-train
#.build/debug/decision_tree_generator --forest 24 --no-prune -n 28 -t /qp/ntar_validated/$1-test /qp/ntar_validated/$1-train


# re-compile trees
cd ../StarDecisionTrees
./build_lib.sh

# test them
cd ../decision_tree_generator

# without a clean here the recompled .a file from above gets missed
rm -rf .build
swift build

swift run decision_tree_generator -v /qp/ntar_validated/$1-test
date







