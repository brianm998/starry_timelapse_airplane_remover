#!/usr/bin/perl

# this script functions as a wrapper around ntar, providing the following features:
#
# - use ffmpeg to allow working directly on video files
# - ntar crash and os killing protection
#

# be aware that this script always re-encodes as ProRes

use strict;

usage() if(scalar(@ARGV) == 0);

my $last_arg = pop @ARGV;

my $args = join(' ', @ARGV);

my $restarts = 0;
my $encode_results = 0;

my $ntar_last_arg = $last_arg;

if(-f $last_arg) {
  validate();
  validate_exiftool();
  $encode_results = 1;
  $ntar_last_arg = extract_image_sequence_from_video($last_arg, "FRAME_", "tiff");
}

while(system("ntar $args $ntar_last_arg") != 0) {
  $restarts++;
  print "trying again\n";
}

print "doh!, ntar crashed $restarts times :(\n" unless($restarts == 0);

if($encode_results) {
  # find output dirname from ntar
  $ntar_last_arg =~ s/[.][^.]+$//; # remove any file extension
  open my $fh, "ls -d $ntar_last_arg"."-ntar* |" or die $!;
  my $ntar_output_dir = <$fh>;
  chomp $ntar_output_dir;
  close $fh;

  my $output_video_filename = render($ntar_output_dir, "FRAME_");

  system("rm -rf $ntar_output_dir");
  system("rm -rf $ntar_last_arg");

  print("rendered $output_video_filename\n");
}

sub extract_image_sequence_from_video($$$) {
  my ($video_filename, $img_prefix, $image_type) = @_;

  my $output_dirname = $video_filename;
  my $output_dir = "";
  if($video_filename =~ m~^(.*/)([^/]+)$~) {
    $output_dir = $1;
    $output_dirname = $2;	# remove path
  }

  $output_dirname =~ s/[.][^.]+$//; # remove any file extension


  $output_dirname = "$output_dir/$output_dirname" if($output_dir ne "");

  mkdir $output_dirname;	# errors?

  system("ffmpeg -i $video_filename $output_dirname/$img_prefix"."%05d.$image_type");

  return $output_dirname;	# the dirname of the image sequence
}

sub validate() {
  # we need ffmpeg

  die <<END
ERROR

ffmpeg is not installed

visit https://ffmpeg.org

and install it to use this tool
END
    unless(system("which ffmpeg >/dev/null") == 0);
}

# this renders an image sequence from the given dirname into a video file
# for now, just full resolution ProRes high quality
# if successful, the filename of the rendered video is returned
sub render($$) {
  my ($image_sequence_dirname, $sequence_image_prefix) = @_;

  opendir my $source_dir, $image_sequence_dirname or die "cannot open source dir $image_sequence_dirname: $!\n";

  my $test_image;

  # read all files at the first level of the source dir
  foreach my $filename (readdir $source_dir) {
    next if($filename =~ /^[.]/);
    $test_image = $filename;
    last;
  }

  closedir $source_dir;

  # XXX handle error here
  my $exif = run_exiftool("$image_sequence_dirname/$test_image");

  my $image_width = $exif->{ImageWidth};
  my $image_height = $exif->{ImageHeight};

  if($image_width == 0 || $image_height == 0) {
      # XXX unhandled problem
  }

  # calculate aspect ratio from width/height
  my $aspect_ratio = get_aspect_ratio($image_width, $image_height);

  my $output_video_filename = $image_sequence_dirname;

  # remove the sequence image prefex if it happens to be part of the video filename
  $output_video_filename =~ s/$sequence_image_prefix//;

  $output_video_filename .= ".mov";

  if(-e $output_video_filename) {
    print("$output_video_filename already exists, cannot render\n");
    return undef;
  } else {
    # render
      # full res, ProRes high quality
    my $ffmpeg_cmd = "ffmpeg -y -r 30 -i $image_sequence_dirname/$sequence_image_prefix%05d.tiff -aspect $aspect_ratio -c:v prores_ks -pix_fmt yuv444p10le -threads 0 -profile:v 4 -movflags +write_colr -an -color_range 2 -color_primaries bt709 -colorspace bt709 -color_trc bt709 -timecode 00:00:00:00 ";

    $ffmpeg_cmd .= $output_video_filename;

    if (system($ffmpeg_cmd) == 0) {
      return $output_video_filename;
    } else {
      print("render failed :("); # why?
    }
  }
}


use Text::CSV qw( csv );

# I realize that exiftool is written in perl, can probably just use it directly

sub validate_exiftool() {
  # we need exiftool

  die <<END
ERROR

exiftool is not installed

visit https://exiftool.org

and install it to use this tool
END
    unless(system("which exiftool >/dev/null") == 0);
}

# returns a basic map of the exiftool output for the given filename
sub run_exiftool($) {
  my ($filename) = @_;
  my $ret = {};

  my $csv = Text::CSV->new ({ binary => 1, auto_diag => 1 });
  open my $fh, "exiftool -csv $filename |" or die $!;

  # first row is keys
  my $row1 = $csv->getline ($fh);
  # second row is values
  my $row2 = $csv->getline ($fh);

  # no other rows

  my $exif_data = {};

  for(my $i = 0 ; $i < scalar @$row1 ; $i++) {
    $exif_data->{$row1->[$i]} = $row2->[$i];
  }

  close $fh;

  return $exif_data;
}

sub get_aspect_ratio($$) {
  my ($width, $height) = @_;
  print "($width, $height)\n";
  my $ratio_width = $width/$height;
  my $ratio_height = 1;

  if (is_int($ratio_width)) {
    return "$ratio_width/$ratio_height";
  } else {
    # not sure we need ints here
    # need to multiply
    my ($a, $b) = recurse_to_find_integers($ratio_width, $ratio_height, 2);
    return "$a/$b" if(defined $a && defined $b);
    return "$width/$height";	# unable to find integers, return original values
  }
}

sub recurse_to_find_integers($$$) {
  my ($left, $right, $multiplier) = @_;

  if(is_int($left*$multiplier) && is_int($right*$multiplier)) {
    return ($left*$multiplier, $right*$multiplier);
  } else {
    return undef if($multiplier > 1000);
    return recurse_to_find_integers($left, $right, $multiplier+1);
  }
}

sub is_int($) {
  my ($value) = @_;

  return $value == int $value;
}

sub usage() {
  print "Need to specify either a video filename or an image sequence dirname to process\nUsage:\n$0 -n [max processes] [video filename or image sequence dirname]\n";
  exit;
}
