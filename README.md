
# Nighttime Timelapse Airplane Remover

The Nighttime Timelapse Airplane Remover (ntar) is a software package that performs the removal of airplane streaks from night time timelapse videos.

## Comparison videos from northern esmerelda county, Nevada, USA

It was this nearly cloudless night last year that kicked off this project for me.

The processed video was run through the command line ntar first, and then hand edited with the new gui version of ntar frame by frame for some corrections.

### original video

https://vimeo.com/803304507

### processed with ntar 0.2.0

https://vimeo.com/803303679

## Description

NTar operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.  It has been designed as part of a post processing workflow, so it currently only operates on 16 bit tiff still image sequences.

To operate directly on video files, the ntar.pl script is included to use ffmpeg to de-code the given video and then re-encode the ntar results into a video.

The purpose of ntar is to remove airplane and satellite streaks from overnight timelapse videos.  These can be distrating to viewers, who often assume them to be 'shooting stars', because the move so fast in a timelapse.  For years I've accepted airplanes in the night sky in my timelapses.  When using shorter shutter speeds, I like them when they can be seen landing.  But when out in really dark skies in the middle of nowhere, I don't like them to show up, and I think such videos often benefit from removing airplanes.

Be aware that meteor trails will be removed as well, these can be re-added later with the gui front end, but flash on a single frame usually.  I've considered adding a meteor enhancing feature to spread out selected meteors over a few frames, but have yet to do so.

## Software

NTar contains three applications:
 - the ntar command line application
 - a gui front end
 - a machine learning decision tree generator

These three applications are all based upon the same core logic and data models.

The code is all written in swift.

### Algorithm

At a high level, ntar operates in a number of steps:

1. look at every pixel in every frame and look for pixels that are markedly brighter than those in adjecnt frames.  These are called outliers.
2. within each frame, group these pixels into groups, discarding some smaller ones.  These are called outlier groups.
3. apply some selection criteria to determine which outlier groups to paint over
4. paint over selected outlier groups in each frame with pixel values from an adjecent frame 

The tricky part is step #3, trying to decide what outlier groups in the image are airplane streaks.

#### Original Approach

My first approach was very iterative, and after much iteration ended up in a place where it worked 'pretty good'.  This means that it got almost all of the airplane streaks, and not too many other things.

I applied many different approaches, like data from the Hough Transform, as well as an initial histogram based statistical approach to outlier groups based upon things like size and how much the hough transform data looks like a line.  I then did a few more passes of analyzing the outlier groups between neighboring frames, to catch smaller airplane streaks closer to the horizon based upon a similar outlier group in other frames.

While this approach was getting better results, I ended up with a bunch of magic numbers and hard coded decisions about edge cases.  Without any real source of what is or what is not an airplane streak, there was a lot of guessing involved.

#### Manual Visual Determination

My next step was to build a gui application off of the same code base.

This gui application is still in development, but allows a user to load up an image sequence, and frame by frame inspect how the outlier groups have been selected already.  It also allows the user to then change this manually by touching on one or more of them.  This can be time consuming, but in the end you end up with no false positive or negative results.

This both allows you to render the given video with as many airplanes removed as possible, and also generates a data set of outlier groups where we know a-priori if they are airplanes or not.

#### Teach the Machine

After I went through a few image sequences and manually validated every frame, I had a start for a test data set for machine learning.

Still under development is a decision tree generator which gathers and crunches a bunch of outlier test data to write out a decision tree that can be used to determine outlier group paintability.

The idea is to generate a large data set, create more outlier group decision parameters, and tweak the decision tree generation logic further to get better results.  Work in progress.

## Getting Started

The fastest way to get started if you've got macos swift command line support already is to clone this repo and run install.sh, which will build a release build of command line ntar and put that into /usr/local/bin, along with the ntar.pl wrapper.

If you're not a developer, then right now if you're on macos simply asking me for a binary will work.  If you're on windows we still need a windows swift developer to look at this.  I do have a small old linux box but I've not taken the time to get ntar to compile there, let me know if that is of interest to you.

Still under active development, feel free to reach out to me if you have any questions.

