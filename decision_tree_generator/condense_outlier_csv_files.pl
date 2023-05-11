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

# this script combines all of the outlier values from these sequences into the given output dir

my $output_dir = shift;

mkdir $output_dir;

my $sequences = json::read("validated_sequences.json");

foreach my $basedir (keys %$sequences) {
  chdir $basedir;

  foreach my $sequence (@{$sequences->{$basedir}}) {
    print "sequence $sequence\n";
    my $dirname = "$basedir/$sequence"."-outliers";
    print "dirname $dirname\n";

    system "cat $dirname/*/positive_data.csv >> $output_dir/positive_data.csv\n";
    system "cat $dirname/*/negative_data.csv >> $output_dir/negative_data.csv\n";
    system "cp $dirname/0/types.csv $output_dir\n"; # XXX should really make sure these are all the same
  }
}



