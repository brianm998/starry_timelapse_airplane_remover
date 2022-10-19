#!/bin/perl

use strict;

# this reads in csv data like this:

# 56,17,227,1
# 19,24,143,0

# which is
# width,height,size,is_airplane

my $airplane_records = [];
my $non_airplane_records = [];

my $mode = shift;

my $code_only = 0;

# when run without this arg show debug info that helps improve the alg with more data
# when run with this arg only output the generated swift code
$code_only = 1 if($mode eq '--generate-swift');

# read all csv records from STDIN
while (<>) {
  if (/^(\d+),(\d+),(\d+),(\d+)$/) {
    my ($width, $height, $size, $is_airplane) = ($1, $2, $3, $4);
    if ($is_airplane == 1) {
      push @$airplane_records, [$width, $height, $size];
    } else {
      push @$non_airplane_records, [$width, $height, $size];
    }
  }
}

my $number_airplane_records = scalar(@$airplane_records);
my $number_non_airplane_records = scalar(@$non_airplane_records);

unless ($code_only) {
  print "we have $number_airplane_records airplane records\n";
  print "we have $number_non_airplane_records non_airplane records\n";
}

my $date = `date`;
chomp $date;

my $epoc_seconds = time;

# print out the beginning of the swift code
print <<EOF
import Foundation

// generated on $date

// data used from $number_airplane_records airplane records and $number_non_airplane_records non airplane records

// this is auto generated code, run regenerate_shouldPaint.sh to remake it, DO NOT EDIT BY HAND

// the unix time this file was created
let paint_group_logic_time = $epoc_seconds

func shouldPaintGroup(min_x: Int, min_y: Int,
                      max_x: Int, max_y: Int,
                      group_name: String,
                      group_size: UInt64) -> Bool
{
    // the size of the bounding box in number of pixels
    let max_pixels = (max_x-min_x)*(max_y-min_y)

    // how much (betwen 0 and 1) of the bounding box is filled by outliers?
    let amount_filled = Double(group_size)/Double(max_pixels)

    let bounding_box_width = max_x-min_x
    let bounding_box_height = max_y-min_y

    // the aspect ratio of the bounding box.
    // 1 is square, closer to zero is more regangular.
    var aspect_ratio: Double = 0
    if bounding_box_width > bounding_box_height {
        aspect_ratio = Double(bounding_box_height)/Double(bounding_box_width)
    } else {
        aspect_ratio = Double(bounding_box_width)/Double(bounding_box_height)
    }

EOF
  ;

my ($airplane_min_size, $airplane_max_size) = size_range($airplane_records);
my ($non_airplane_min_size, $non_airplane_max_size) = size_range($non_airplane_records);


unless ($code_only) {
  print("    airplanes were [$airplane_min_size, $airplane_max_size] in size out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_size, $non_airplane_max_size] in size of ",scalar(@$non_airplane_records)," records\n");
}

print "    // outlier groups smaller aren't airplanes\n";
print "    if(group_size < $airplane_min_size) { return false } // not airplane\n\n";
print "    // outlier groups larger are airplanes\n";
print "    if(group_size > $non_airplane_max_size) { return true } // is airplane\n\n";


unless ($code_only) {
  print "there is a no gap between airplanes and non airplanes\n";
  print "there are both airplanes and not airplanes between sizes $airplane_min_size and $non_airplane_max_size\n";
}

my $new_airplane_arr = [];

foreach my $record (@$airplane_records) {
  push @$new_airplane_arr, $record if($record->[2] < $non_airplane_max_size);
}
$airplane_records = $new_airplane_arr;

my $new_non_airplane_arr = [];

foreach my $record (@$non_airplane_records) {
  push @$new_non_airplane_arr, $record if($record->[2] > $airplane_min_size);
}
$non_airplane_records = $new_non_airplane_arr;

unless ($code_only) {
  print "we now have ",scalar(@$airplane_records)," airplane records\n";
  print "we now have ",scalar(@$non_airplane_records)," non_airplane records\n";
}
my ($airplane_min_aspect, $airplane_max_aspect) = aspect_range($airplane_records);
my ($non_airplane_min_aspect, $non_airplane_max_aspect) = aspect_range($non_airplane_records);

unless ($code_only) {
  print("    airplanes were [$airplane_min_aspect, $airplane_max_aspect] in aspect out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_aspect, $non_airplane_max_aspect] in aspect of ",scalar(@$non_airplane_records)," records\n");
}

# now filter airplanes on aspect ratio

$new_airplane_arr = [];

print ("    // outlier groups with a smaller aspect ratio are airplanes\n"); 
print ("    if(aspect_ratio < $non_airplane_min_aspect) { return true } // is airplane\n\n");

foreach my $record (@$airplane_records) {
  push @$new_airplane_arr, $record if(aspect_ratio_for_record($record) < $non_airplane_min_aspect);
}
$airplane_records = $new_airplane_arr;

unless ($code_only) {
  print "we now have ",scalar(@$airplane_records)," airplane records\n";
}

my ($airplane_min_fill, $airplane_max_fill) = fill_range($airplane_records);
my ($non_airplane_min_fill, $non_airplane_max_fill) = fill_range($non_airplane_records);

unless ($code_only) {
  print("    airplanes were [$airplane_min_fill, $airplane_max_fill] in fill out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_fill, $non_airplane_max_fill] in fill of ",scalar(@$non_airplane_records)," records\n");
}

# now filter on fill percentage

$new_non_airplane_arr = [];

print("    // outlier groups with a higher fill amount aren't airplanes\n");
print("    if(amount_filled > ",$airplane_max_fill/100,") { return false } // notAirplane\n\n");
print("    // outlier groups with a lower fill amount aren't airplanes\n");
print("    if(amount_filled < ",$airplane_min_fill/100,") { return false } // notAirplane\n\n");

foreach my $record (@$non_airplane_records) {
  my $width = $record->[0];
  my $height = $record->[1];
  my $size = $record->[2];
  if ($width != 0 && $height != 0) {
    my $amt_pct = $size/($width*$height)*100;

    if ($amt_pct < $airplane_max_fill && $amt_pct > $airplane_min_fill) {
      push @$new_non_airplane_arr, $record;
    }
  }
}
$non_airplane_records = $new_non_airplane_arr;

unless ($code_only) {
  print "we now have ",scalar(@$non_airplane_records)," non_airplane records\n";
}

($airplane_min_size, $airplane_max_size) = size_range($airplane_records);
($non_airplane_min_size, $non_airplane_max_size) = size_range($non_airplane_records);

unless ($code_only) {
  print("    airplanes were [$airplane_min_size, $airplane_max_size] in size out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_size, $non_airplane_max_size] in size of ",scalar(@$non_airplane_records)," records\n");
}

($airplane_min_fill, $airplane_max_fill) = fill_range($airplane_records);
($non_airplane_min_fill, $non_airplane_max_fill) = fill_range($non_airplane_records);
unless ($code_only) {
  print("    airplanes were [$airplane_min_fill, $airplane_max_fill] in fill out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_fill, $non_airplane_max_fill] in fill of ",scalar(@$non_airplane_records)," records\n");
}

($airplane_min_aspect, $airplane_max_aspect) = aspect_range($airplane_records);
($non_airplane_min_aspect, $non_airplane_max_aspect) = aspect_range($non_airplane_records);
unless ($code_only) {
  print("    airplanes were [$airplane_min_aspect, $airplane_max_aspect] in aspect out of ",scalar(@$airplane_records)," records\n");
  print("non airplanes were [$non_airplane_min_aspect, $non_airplane_max_aspect] in aspect of ",scalar(@$non_airplane_records)," records\n");
}

print("    // outlier groups with a larger aspect ratio aren't airplanes\n");
print("    if(aspect_ratio > $non_airplane_min_aspect) { return false } // notAirplane\n\n");
print("    //  groups with a smaller aspect ratio are airplanes\n");
print("    if(aspect_ratio < $airplane_max_aspect) { return true } // airplane\n\n");

if ($non_airplane_min_aspect > $airplane_max_aspect) {
  print"    // with $non_airplane_min_aspect > $airplane_max_aspect,\n";
  print"    // no outlier groups from the testing group reached this point\n\n";
  print"    Log.w(\"unable to properly detect outlier with width \\(bounding_box_width) height \\(bounding_box_height) and size \\(group_size) further data collection and refinement in $0 is necessary to resolve this\")\n";
} else {
  print"    // with $non_airplane_min_aspect < $airplane_max_aspect,\n";
  print"    // some outlier groups can reach this point.\n";
  print"    // They will be assumed to not be airplanes.\n\n";
  print"    // further work on the logic in $0 should happen.\n";
}

$new_airplane_arr = [];
foreach my $record (@$airplane_records) {
  push @$new_airplane_arr, $record if(aspect_ratio_for_record($record) > $airplane_max_aspect);
}
$airplane_records = $new_airplane_arr;

$new_non_airplane_arr = [];
foreach my $record (@$non_airplane_records) {
  push @$new_non_airplane_arr, $record if(aspect_ratio_for_record($record) < $non_airplane_min_aspect);
}
$non_airplane_records = $new_non_airplane_arr;

print <<END

    return false // guess it's not an airplane
}
END
  ;
unless ($code_only) {
  print "we now have ",scalar(@$airplane_records)," airplane records\n";
  print "we now have ",scalar(@$non_airplane_records)," non_airplane records\n";
}

#    foreach my $record (@$airplane_records) {
#      print "AR: $record->[0] $record->[1] $record->[2] $record->[3]\n";
#    }

#    foreach my $record (@$non_airplane_records) {
#      print "NA: $record->[0] $record->[1] $record->[2] $record->[3]\n";
#    }



########
# subs #
########

sub size_range($) {
    my ($records) = @_;

    my $min = 1000000000000;
    my $max = 0;

    foreach my $record (@$records) {
	$min = $record->[2] if($record->[2] < $min);
	$max = $record->[2] if($record->[2] > $max);
    }

    return ($min, $max);
}

sub fill_range($) {
    my ($records) = @_;

    my $min = 1000000000000;
    my $max = 0;

    foreach my $record (@$records) {
	my $width = $record->[0];
	my $height = $record->[1];
	my $size = $record->[2];
	if($width != 0 && $height != 0) {
	    my $amt_pct = $size/($width*$height)*100;
	    $min = $amt_pct if($amt_pct < $min);
	    $max = $amt_pct if($amt_pct > $max);
	}
    }

    return ($min, $max);
}

sub aspect_ratio_for_record($) {
  my ($record) = @_;

  my $aspect = 1;
  my $width = $record->[0];
  my $height = $record->[1];
  if ($width != 0 && $height != 0) {
    if ($width > $height) {
      $aspect = $height/$width;
    } else {
      $aspect = $width/$height;
    }
  }
  return $aspect;
}

sub aspect_range($) {
  my ($records) = @_;

  my $min = 1000000000000;
  my $max = 0;

  foreach my $record (@$records) {
    my $aspect = aspect_ratio_for_record($record);

    $min = $aspect if($aspect < $min);
    $max = $aspect if($aspect > $max);
  }

  return ($min, $max);
}
