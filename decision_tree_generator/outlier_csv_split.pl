#!/usr/bin/perl

use strict;

# this script splits out a single dir of all outlier values into a train and test group

# it's really slow, and could be improved

my $input_dir = shift;

my $train_dir = "$input_dir"."-train";
my $test_dir = "$input_dir"."-test";


mkdir $train_dir;
mkdir $test_dir;

my $is_test = 0;

my $train_to_test_multiplier = 9;
my $train_count = 0;

system("cp $input_dir/types.csv $test_dir");
system("cp $input_dir/types.csv $train_dir");

open my $fh, "$input_dir/positive_data.csv";

my $positive_test_data = "";
my $positive_train_data = "";

while(<$fh>) {
    if($is_test) {
	$positive_test_data .= $_;
    } else {
	$positive_train_data .= $_;
	$train_count++;
    }
    if ($is_test) {
      $is_test = 0;
    } elsif ($train_count >= $train_to_test_multiplier) {
      $is_test = 1;
      $train_count = 0;
    }
}
close $fh;

open(my $fh, '>', "$test_dir/positive_data.csv");
print $fh $positive_test_data;
close $fh;

open(my $fh, '>', "$train_dir/positive_data.csv");
print $fh $positive_train_data;
close $fh;


print "starting negative data\n";

my $negative_test_data = "";
my $negative_train_data = "";

open my $fh, "$input_dir/negative_data.csv";
while(<$fh>) {
    if($is_test) {
	$negative_test_data .= $_;
    } else {
	$negative_train_data .= $_;
	$train_count++;
    }
    if ($is_test) {
      $is_test = 0;
    } elsif ($train_count >= $train_to_test_multiplier) {
      $is_test = 1;
      $train_count = 0;
    }
}
close $fh;

open(my $fh, '>', "$test_dir/negative_data.csv");
print $fh $negative_test_data;
close $fh;

open(my $fh, '>', "$train_dir/negative_data.csv");
print $fh $negative_train_data;
close $fh;







