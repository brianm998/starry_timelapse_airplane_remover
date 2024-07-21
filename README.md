
# Starry Timelapse Airplane Remover

The Starry Timelapse Airplane Remover (Star) is a software package that performs the removal of airplane streaks from night time timelapse videos.

## Comparison videos from northern esmerelda county, Nevada, USA

It was this nearly cloudless night last year that kicked off this project for me.

The processed video was run through the command line Star first, and then hand edited with the new gui version of star frame by frame for some corrections.

### original video

https://vimeo.com/803304507

### processed with Star 0.2.0

https://vimeo.com/803303679


## More recent comparison videos

Taken from the Smith Creek Valley in central Nevada, on a night with some moonlight.  The moon sets just before 40 seconds into it.

### original video

https://vimeo.com/988073522

### processed with Star 0.6.6

https://vimeo.com/950955396

## Description

Star operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.  It has been designed as part of a post processing workflow, so it currently only operates on 16 bit tiff still image sequences.

To operate directly on video files, the star.pl script is included to use ffmpeg to de-code the given video and then re-encode the star results into a video.

The purpose of Star is to remove airplane and satellite streaks from overnight timelapse videos.  These can be distrating to viewers, who often assume them to be 'shooting stars', because the move so fast in a timelapse.  For years I've accepted airplanes in the night sky in my timelapses.  When using shorter shutter speeds, I like them when they can be seen landing.  But when out in really dark skies in the middle of nowhere, I don't like them to show up, and I think such videos often benefit from removing airplanes.

Be aware that meteor trails will be removed as well, these can be re-added later with the gui front end, but flash on a single frame usually.  I've considered adding a meteor enhancing feature to spread out selected meteors over a few frames, but have yet to do so.

Latest versions of Star use align_image_stack from Hugin to align stars.  Currently this needs to be installed separately from Star itself to take advantage of this feature.

Download and install Hugin for free:

https://hugin.sourceforge.io/download/

Star needs the align_image_stack utility from Hugin

/Applications/Hugin/Hugin.app/Contents/MacOS/align_image_stack

Star will still work without align_image_stack, but the results will be that the layer masks will reveal a slightly diferent part of the sky vs the aligned image.

## Software

Star contains three applications:
 - the star command line application
 - a gui front end
 - a machine learning decision tree generator

These three applications are all based upon the same core logic and data models.

The code is all written in swift.

### Algorithm

At a high level, Star operates in a number of steps for each frame:

1. star-align a neighboring frame
2. subtract the image from step #1 from the frame being processed
3. detect bright groups of pixels in the image from step #2
4. apply some heuristics to filter out a lot of the groups from step #3
5. classify these groups using machine learning to decide which ones to derive layer masks from
6. create a layer mask for this frame using the classified groups from step #5
7. use the layer mask from step #6 and the star-aligned neighbor frame from step #1 to generate the output image for this frame

As of Star v 0.4.0, detection is done via star-aligned images.  Each frame has a neighboring frame mapped to it via hugin's align_image_stack utility.  This makes the stars show up in close to the same spot in both images, while things like the earth are moved.  The effect of this is that, with proper alignment, the area of a frame that is covered by the streak of an airplane will be replace with a closer part of the sky from the neighboring frame.

Having mapped a comparison image makes detection a lot more capable, i.e. smaller differences between the images can be found, with fewer false positives.

The heuristics from step #4 can be controlled on the command line with the --detectionType argument.  Really wide lenses like 12mm can result in a less accurate star alignment, which can give a noiser subtraction image.  Shorter lenses like 20mm or narrower can result in much closer star alignment and a much cleaner subtration image.

The machine learning is implemented with a trained decision tree.  Star contains logic to build forests of decision trees from validated image sequences.  

If any errors are noticed in the rendered videos, the Star gui appliation can be used to modify each frame as necessary.

Painting is done from the star-aligned images, which means that the pixels painted over are going to be closer to the part of the sky that should be there.

#### Original Approach

My first approach was very iterative, and after much iteration ended up in a place where it worked 'pretty good'.  This means that it got almost all of the airplane streaks, and not too many other things.

I applied many different approaches, like data from the Hough Transform, as well as an initial histogram based statistical approach to outlier groups based upon things like size and how much the hough transform data looks like a line.  I then did a few more passes of analyzing the outlier groups between neighboring frames, to catch smaller airplane streaks closer to the horizon based upon a similar outlier group in other frames.

While this approach was getting better results, I ended up with a bunch of magic numbers and hard coded decisions about edge cases.  Without any real source of what is or what is not an airplane streak, there was a lot of guessing involved.

#### Manual Visual Determination

My next step was to build a gui application off of the same code base.

This gui application is still in development, but allows a user to load up an image sequence, and frame by frame inspect how the outlier groups have been selected already.  It also allows the user to then change this manually by touching on one or more of them.  This can be time consuming, but in the end you end up with no false positive or negative results.

This both allows you to render the given video with as many airplanes removed as possible, and also generates a data set of outlier groups where we know a-priori if they are airplanes or not.

#### Teach the Machine

The next step was to use this growing data set to enable the code to classify the data.  The classification is binary, paint over each group of identified pixels or not.

The current machine learning approach involves supervised training with a manually coded set of features.  Some of the features are simple, like number of pixels, others are more complex and involve inspecting neighboring frames.  

Given a set of labeled data, the decision tree generator writes out a tree of decisions based upon different classification features of the data at each step.  At the end leaves, it returns a value between -1 and 1 inclusive.  1 means paint this group of pixels, -1 means don't.  0 is inconclusive.  Values can be inbetween, showing a level of uncertainity.

If a new classification feature is later added, the decision tree generator can be recompiled and re-run on the same existing data set to potentially improve accuracy.

The best classifier I've developed so far involves splitting up the training data into chunks, and removing one of these chunks from the training set for one of the trees.  I then test these trees against a test set of data that they were not trained on, to produce a score for each tree.  A higher level classifier then combines the scores from all of the trees from this training set, weighted by their scores.  This is similar to getting a group consensus on the final result.  Depending upon the training set, this can boost the overall accuracy by 0.5-2%.  Star 0.3.2 has a classifier that showed 98.61% accuracy on non trained test data.  Working to increase the number of nines.

A future approach is to try something like adaboost.

A completely different approach would be to use a convolutional neural network to better visually identify pixel groups.

Regardless of the classifier used, more data to train means more accuracy in the field.  A future feature of Star will allow users to submit data sets they've validated themselves, to allow for a larger data set to train from.   

## Getting Started

Download the latest release from here:

https://github.com/brianm998/starry_timelapse_airplane_remover/releases

Two packages are available for installation, the command line application is called 'star', the gui application is called Star.app.

One or both can be installed.

Still under active development, feel free to reach out to me if you have any questions.

###

Current workflow

The workflow that I'm using with Star right now is to process via star as the very final step of image sequence processing before rendering video files.

What star needs is a sequence of 16 bit tiff files.  If anyone works with any other kind of file, feel free to file a feature request for that.

I use Adobe Lightroom w/ LRTimelapse to generate the initial set of images for each sequence I shoot.  I then process with other software, oftentimes Topaz Denoise for the overnight shots.

Next, I run `star -w (path to image sequence)` on the command line to run the initial processing of the sequence through Star.  This generates a number of directories next to the one you passed, with the same name followed by an extention.  This includes the fully processed set of images that is generated without the `-w` on the commane line, as well as a bunch of sidecar directories with extensions, including a json file of the config that the sequence was processed with.  

This json config file can be then opened in the Star GUI application, to:

 - preview the changes before rendering it
 - make adjustements to any of the changes

If I'm generating a set of data to train from, I'll step through each frame, looking at the parts of the image that have been classified one way or the other to make sure they are right.  This can take an hour or more for a sequence of 2000 frames.

If I'm not planning on using a sequence for data training, I'll first play and scrub through the video in the Star gui to see if anything looks wrong.  If so, I'll then narrow down on the frame(s) in question and adjust just those.  This can be a lot faster.

## Known issues

### Clouds

When airplanes go through clouds, depending upon how close they are to both you and the clouds, some amount of brightness will increase in the clouds.

As of Star 0.3.3, the brightest part of this will be detected.  However, after removal, a ghost airplane is sometimes visible, sometimes also with a lasting contrail.  This means that these airplanes are not completely removed, but largely reduced.

### Undetected Vehicles

As of Star 0.6.7, detection has improved a lot, but is not perfect.

This includes airplanes that appear as a sequence of small bright dots without changed pixels inbetween them.  The closer the changed pixels look like a line the more likely they will be detected.  Bumping up the --detectionType argument on the cli to exp can result in more detection of these.

Also usually not detected are really slow moving satellites.  

Sometimes detected are faster very dim satellites, where only part of their path is bright enough to trigger detection, but not always.

Further work is required to address these issues.

### Crashes

Earlier versions of Star were prone to crashing under high load.  Star 0.6.7 is much more stable in this regard.

### Slow

Processing of large sequences of high resolution images can be slow.  While Star 0.6.7 is a lot faster than earlier iterations, processing an image sequence of 1000 images at 12 megapixels can take more than an hour.  42 megapixel image sequences generally finish overnight.  The --detectionType command line argument effects the processing speed.

This slowness is one reason I leave much of the processing to the command line and come back later when it's complete.

### Gui not complete

The Star gui application does work, but the workflow of working only in the gui isn't fully fleshed out yet.

Currently I run `star -w` on the command line, and then load up the resulting config file in the gui to correct for any errors after the sequence has been processed on the command line first.

In the future I'll make the GUI work better standalone.  Right now it's best used for fixing errors in the classifier, both for creating more training data, as well as making better looking videos.

### Classifier not always right

The machine learning classifier is a work in progress.  While it has gotten farther than 98.6% accuracy on test data, your data may vary.  A longer term feature is to allow users to send in data from corrected sequences to further train the classifier.

Common misclassifications are currently:
 - small airplane streaks close to the horizon
 - certain lower level faster moving clouds
 - some parts of terrain

More data and further algorithmic improvements should increase accuracy and make manually validation results both faster and less necessary.

Ideally Star will get to a place where for most image sequences it can just 'work' without user doing anything besides telling it what image sequence to process.

Right now it can do that, if a few small errors are ok.  This means a few airplanes are still popping up in one spot or two, and some clouds or terrain are changed when they shouldn't be.