#!/usr/bin/perl

use strict;

# write a swift file listing all current decision trees in a map

my $trees;

opendir my $dir, 'Sources/StarDecisionTrees' or die "cannot open dir: $!\n";
foreach my $filename (readdir $dir) {
  # filename looks like OutlierGroupDecisionTreeForest_ec60776b.swift
  if($filename =~ /_([a-f\d]+)[.]swift$/ && $filename !~ /#/)  {
    my $hash = $1;
    $filename =~ s/[.]swift$//;
    $trees->{$hash} = $filename;
  }
}
closedir $dir;

open OUTPUT, ">Sources/StarDecisionTrees/StarDecisionTrees.swift";

print OUTPUT "import Foundation\n";
print OUTPUT "import StarCore\n\n";
print OUTPUT "public let decisionTrees: [String: NamedOutlierGroupClassifier] = [\n";
my $number_of_trees = keys %$trees;
if($number_of_trees > 0) {
  foreach my $hash (keys %$trees) {
    print OUTPUT "    \"$hash\": $trees->{$hash}(),\n";
  }
} else {
  print OUTPUT ":";
}
print OUTPUT "]\n";

close OUTPUT;
