
# Nighttime Timelapse Airplane Remover

This is a command line utility that removes airplanes streaks from night time timelapse videos.

## Comparison videos from the panamint valley in California:

### original video

https://vimeo.com/775341167

### processed with ntar 0.0.8

https://vimeo.com/775330768

## Description

NTar operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.  It has been designed as part of a post processing workflow, so it currently only operates on 16 bit tiff still image sequences.

To operate directly on video files, the ntar.pl script is included to use ffmpeg to de-code the given video and then re-encode the ntar results into a video.

The purpose of ntar is to remove airplane and satellite streaks from overnight timelapse videos.  These can be distrating to viewers, who often assume them to be 'shooting stars', because the move so fast in a timelapse.  For years I've accepted airplanes in the night sky in my timelapses, and even like them you can see the airplanes landing in an airport.  But when out in really dark skies in the middle of nowhere, IMO the airplanes stick out too much.

Be aware that incoming meteor trails will be caught as well, best to re-introduce those from the original video in post if you want to keep them.

## Technical Details

Ntar is written in swift, and uses only the Foundation, CoreGraphics, Cocoa and ArgumentParser frameworks.  Any swift installation that has these frameworks should be able to compile and run this software.  I've developed it on macos, and can provide binaries for any desktop mac architecture.  It _might_ compile on windows and or linux, let me know if it works for you.

## Getting Started

The fastest way to get started if you've got macos swift command line support already is to clone this repo and run install.sh, which will build a release build of ntar and put that into /usr/local/bin, along with the ntar.pl wrapper.

If you're not a developer, then right now if you're on macos simply asking me for a binary will work.  If you're on windows we still need a windows swift developer to look at this.  I do have a small old linux box but I've not taken the time to get ntar to compile there, let me know if that is of interest to you.

Still under active development, feel free to reach out to me if you have any questions.

## Usage

ntar [image sequence dirname]

or

ntar.pl [image sequence dirname]

or

ntar.pl [filename of video to process]


The output will match the input, i.e. if given an image sequence dirname, ntar will output a matching image sequence dirname suffixed with '-ntar-version...'.

If ntar.pl is given a video filename, the output will be a ProRes video with a similar suffix.

Personally I use https://github.com/brianm998/timelapse_render_daemon for rendering ntar results as part of my timelapse workflow.