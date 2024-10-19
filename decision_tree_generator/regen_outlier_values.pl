#!/usr/bin/perl

use strict;
use JSON;
use Cwd;
use File::Basename;

my $script_dir;	# figure out where this running script exists on disk
BEGIN { $script_dir = Cwd::realpath( File::Basename::dirname(__FILE__)) }

# add this dir to the include path
use lib "${script_dir}/inc";

use json;

# This script regenerates the outlier values from the outlier groups in each validated dir below
# Run this script after adding a new TreeDecisionType decision criteria or modifying how one of the
# existing criteria values is calculated.
# This takes a long time.

my $sequences = json::read("validated_sequences.json");

foreach my $basedir (keys %$sequences) {
  foreach my $sequence_dir (@{$sequences->{$basedir}}) {
    my $sequence = "$basedir/$sequence_dir";

    print "cleansing existing csv files from $sequence\n";

    # get rid of existing csv files
    system "find $sequence"."-outliers -name '*.csv' -exec rm '{}' ';'";

    # remove the output files so star regenerates data for all frames
    system "rm -r $sequence";
  }
}

my $cmd = 'star';

#my $cmd = "~/git/nighttime_timelapse_airplane_remover/cli/memmory_error.pl ";

foreach my $basedir (keys %$sequences) {
  foreach my $sequence_dir (@{$sequences->{$basedir}}) {
    my $sequence = "$basedir/$sequence_dir";
    print "re-generating csv files for $sequence\n";
    if (-f "$sequence"."-outliers/config.json") {
      system "time $cmd -W -w -s $sequence"."-outliers/config.json";
    } elsif (-f "$sequence"."-config.json") {
      system "time $cmd -W -w -s $sequence"."-config.json";
    } else {
      print("no config.json found for $sequence\n");
    }
  }
}



