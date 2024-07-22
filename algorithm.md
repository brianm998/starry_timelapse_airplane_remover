# This document describes the algorithm used by Star to remove airplanes and satellites from image sequences

Written as of Star 0.6.7.

## High level

At a high level, Star processes each frame in the following steps.

1. star-align a neighboring frame
2. subtract the image from step #1 from the frame being processed
3. detect bright groups of pixels in the image from step #2
4. apply some heuristics to filter out a lot of the groups from step #3
5. classify groups left after step #4 using machine learning to decide which ones to derive layer masks from
6. create a layer mask for this frame using the classified groups from step #5
7. use the layer mask from step #6 and the star-aligned neighbor frame from step #1 to generate the output image for this frame

### Step #1, Star Alignment

The first step is to use Hugin's `align-image-stack` utility.  This is a great little program that attempts to align two or more images together.

This alignment is based upon some number of detected control points, i.e the same feature in each frame.  How far away they are from eachother is used to calculate a transformation to all but the first image given in the stack to be aligned.

The logic used is complex math that works well as long as the images are more tha 90% overlapping.  If images have less overlap, manual control point generation is usually necessary.  Thankfully, almost every timelapse has a lot less than 10% change in view between each image.

This means that for both static and moving tripod heads (any number of axes), `align-image-stack` is able to align one of the neighboring frames to each frame that Star is processing.  Typically there will be a very small area around the borders of the frame which have been rotated out.  In practice this is just a handful of pixels, and is not a problem.

The benefits of having a star aligned neighbor frame image for each frame Star processes are:

 - a much more accurate subtraction image in step #2
 - more accurate data to replace unwanted pixels with

Currently Star needs Hugin to be installed to use `align-image-stack`.  If Hugin is not installed, Star will still work, but will suffer noiser subtraction images and replacement data which is not as well aligned.

I've found that `align-image-stack` works really well, even with clouds covering a lot of the sky.  As long as there are a good number of bright stars visible, it will find them for control points.

On 12mm full frame lenses, the alignment of `align-image-stack` is not as good, i.e. some bright stars only partially overlap themselves after alignment, and then partially show up in the subtraction image in step #2.

However, on 14mm lenses `align-image-stack` is a lot better.  And at 20mm or longer, it's really good.  That means that the subraction images are really dark except for areas that include airplanes.

One unfortnate side-effect of aligning images for comparison is that the ground of the image typically gets moved a small amount, even for timelapses captured on a static tripod.  This can be slightly worked around by using the `--ignore-lower-pixels` command line argument, which will not process any pixels that are the given vertical distance from the bottom of the frame.

### Step #2, image subtraction

The second step is to subtract the aligned image from the frame being processed.

if `align-image-stack` is not available, the unchanged neighbor frame is used instead.

This subtraction image is done in greyscale, and records the amount of change in brightness between the frame being processed and one of its neighboring frames.  If the neighbor has been aligned, then almost all of the bright changes in the sky are a result of things like airplanes.  Clouds can also change brightness levels, even with really dark skies, as they can reveal stars as they move.

The subtraction is really just taking each pixel value and subtracting the neibhoring frame's value for the same pixel.

### Step #3, detect groups of bright pixels in the subtraction image 

In the third step, Star sorts all of the pixels in the subtraction image from step #2 by brightness, brightess first.

Star then iterates, brightest pixel first, and looks for pixels around each bright pixel that are not too much darker.  This creates a potentially large number of groups of brighter pixels.

These are called `Blobs` in the Star code.

### Step #4, apply heuristics to filter out groups

In step #4, a set of heuristics is applied to the potentially large group of blobs from step #3.

This can be controlled the `--detection-type` command line argument.

Many of the smaller blobs that are not close to any other blos are removed here, as well as a number of other techniques.

Using different versions of `--detection-type` will result in more Blobs making it past this step.

### Step #5, use machine learning to classify bright groups

At this point, what are called `Blob`s in the code are promoted to `OutlierGroup`s.

Each `OutlierGroup` is able to provide a list of classification criteria for itself.

Some of these are very basic, like the number of pixels, their brightness, the size of their bounding box, their position in the frame, etc.

Others are more complicated, involving things like the Kernel Hough Transform to attempt to detect lines.

Data from neighboring frames is used as well, things like how many pixels in frames close by are also an outlier at the same place.  Airplanes tend to streak across frames, not touching the same pixel twice in adjecent frames.

All of this data is fed into a machine learning system developed for Star, using decision trees.

For each `OutlierGroup`, the machine learning system will output a real number value between -1 and 1.  -1 means that Star should leave it alone.  1 means that Star should include the pixels from this `OutlierGroup` in the layer mask for step #6.  Zero is wholly unclear.  Any other value betwee -1 and 1 is a guess, multiply by 100 to get percentage.  Negative values mean likelyhood of leaving it alone.  Positive values mean the likeyhood of removing those pixels.

A set of images sequences can be validated as being 'correct' by fixing all of the classification errors using the Star gui application, frame by frame.  This can be tedious, but results in both an image sequence with as much unwanted signal removed as possble, as well as a 'validated' image sequence, which can be used to train the machine learning engine to produce more accurate decision trees.

Each version of Star has some set of decision trees embedded in it.  Currently the approach is to generate a 'forest' of trees, each using a slightly different set of test data.  Then a high level classifier combines all of their scores to get a consensus vote, which tends to increase accuracy by 0.5% or more.

This step is still a work in progess, specifically needing more training data, and potentially more classification criteria as well.

Best accuracy so far is approx 99.1% on test data.

Other approaches to machine learning are also possible, if I find time to pursue them.

### Step #6, layer mask creation

After final classification of all the `OutlierGroup`s for the frame being processed, Star will then create a layer mask.

This 'layer mask' is used in the same way as a layer mask in an application like The Gimp or Photoshop.

The base image is the layer being processed.  On top of that is placed the (hopefully aligned) neighbor frame, using the layer mask created here to determine how much of each pixel from the aligned image to include in the final output.

Currently the layer mask is created by selecting all pixels that are part of `OutlierGroup`s that were scored positive by the machine learning engine.

Next this selection is enlarged by a handful of pixels, at full opacity, meaning that some number of pixels that were not part of any `OutlierGroup` are still fully changed in the output frame.

Then, the selection is feathered a larger amount of pixels.  During this feathering, the opacity of the layer mask decreases to zero at the edges.  This helps to avoid any rough changes when Star replaces pixels in the final output.

### Step #7, generate output image.

Given the layer mask from step #6, and the (hopefully aligned) neighbor frame from step #1, Star simply blends the desired pixels from the neighbor frame into the right places into the frame being processed.

If all has gone well with detection and classification for this frame, then the output image will not include the vast majority of unwanted airplane and satellite signals.

Still hard to detect as of Star 0.6.7, sorted by hardest to detect first:

 - really slow moving satellites
 - really dim satellites, even when moving fast
 - airplanes close to the horizon
 - airplanes that don't show up as a streak, but only a set of unconnected dots



