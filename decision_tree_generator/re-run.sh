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




#
#   - figure out why it's so fricking slow 
#



# re-generate the outlier values from the outlier groups themselves
# this step can take a long time, and only needs to be re-run when
# the OutlierGroup classification features are updated, to either
# give different values for existing features, or to add or remove features.

#./regen_outlier_values.pl

# apply outlier group classification to the raw outlier feature data
# to sort them into positive_data.csv and negative_data.csv files
# this needs to be run whenever the classification of outliers changes,
# or if there are changes from regenerating the outlier values above

cd ../outlier_feature_data_classifier
#swift run -Xswiftc -O  outlier_feature_data_classifier -v ../decision_tree_generator/validated_sequences.json
cd ../decision_tree_generator

# condense the csv files into a single spot
#./condense_outlier_csv_files.pl /qp/star_validated/$1


# split them for test/train
#./outlier_csv_split.pl /qp/star_validated/$1

# build trees
#swift run -Xswiftc -O decision_tree_generator --forest 8 --no-prune -t /qp/star_validated/$1-test /qp/star_validated/$1-train
#.build/debug/decision_tree_generator --forest 12 --no-prune -n 28 -t /qp/star_validated/$1-test /qp/star_validated/$1-train
#.build/debug/decision_tree_generator --forest 16 --no-prune -n 28 -t /qp/star_validated/$1-test /qp/star_validated/$1-train
#.build/debug/decision_tree_generator --forest 24 --no-prune -n 28 -t /qp/star_validated/$1-test /qp/star_validated/$1-train


# re-compile trees
cd ../StarDecisionTrees
./build_debug_lib.sh

# test them
cd ../decision_tree_generator

# without a clean here the recompiled .a file from above gets missed
rm -rf .build

swift run -Xswiftc -O  decision_tree_generator -v /qp/star_validated/$1-test

date


















