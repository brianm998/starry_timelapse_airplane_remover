#!/usr/bin/perl

use strict;

my $input_dir  = shift or die "usage: $0 input_dir output_dir\n";
my $output_dir = shift or die "usage: $0 input_dir output_dir\n";

mkdir $output_dir unless(-d $output_dir);

opendir my $dir, $input_dir or die "cannot open input dir: $!\n";

foreach my $file (readdir $dir) {
  if($file =~ /^(.*)[.]png$/) {
    my ($filename) = ($1);
    system("cp $input_dir/$filename.png $output_dir/$filename"."3x.png");
    my $image_info = `file $input_dir/$filename.png`;
    if($image_info =~ /, (\d+) x (\d+),/) {
      my ($width, $height) = ($1, $2);
      my $twoxWidth = int($width*2/3);
      my $twoxHeight = int($height*2/3);
      my $onexWidth = int($width/3);
      my $onexHeight = int($height/3);
      print "$filename ($width x $height) 2x ($twoxWidth x $twoxHeight) 1x ($onexWidth x $onexHeight)\n";
      system("magick $input_dir/$filename.png -resize $twoxWidth"."x$twoxHeight $output_dir/$filename"."2x.png\n");
      system("magick $input_dir/$filename.png -resize $onexWidth"."x$onexHeight $output_dir/$filename"."1x.png");
    }
  }
}

closedir $dir;
