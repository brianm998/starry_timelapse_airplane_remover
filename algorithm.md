# This document describes the algorithm used by Star to remove airplanes and satellites from image sequences

Written as of Star 0.9.0.

## High level

At a high level, Star processes each frame in the following steps.

As of Star 0.9.0, horizon detection is optional, but defaulted to on.  Turn in off if you don't have a horizon, or aren't worried about airplanes close to the horizon.

1. optionally detect horizon across all frames first
2. align some number of neighboring frames
3. subtract the image(s) from steps #3 and #5 from the frame being processed
4. detect bright groups of pixels in the image from step #3
5. apply some heuristics to filter out a lot of the groups from step #4
6. use grouping and line detection to combine lines of dots
7. throw out a lot of smaller groups
8. classify groups left after step #7 using machine learning to decide which ones to derive layer masks from
9. create a layer mask for this frame using the classified groups from step #8
10. use the layer mask from step #9 and the aligned neighbor frames from step #3 and #5 to generate the output image for this frame

### Step #1, horizon detection

While this step is optional, any timelapse that has an earthly horizon below the stars will benefit from turning this on.

A binary image mask is computed via Otsu's method, using brightness to determine that is in the sky and not.  While not perfect, it does a pretty good job.

Having a horizon mask allows us to know what part of the image is ground, and then compute an earth aligned image as well as a star aligned image.

These are each images computed from a number of neighboring frames, aligned to either the sky or the earth.  

### Step #2, Neignboring Image Alignment

As of Star 0.9.0, neighboring image alignment is no longer done with hugin's align_image_stack.  While align_image_stack did a pretty good job, it struggled at the edges with wide lenses, and had trouble aligning the earth.

If horizon detection is enabled, then Star does two separate kinds of image alignment, one for each the sky and earth, determined by the horizon mask.

If horizon detection is not enabled, then Star does star alignment for the entire frame.

Star alignment is done with opencv2's SIFT (Scale Invariant Feature Transform).  The area of each frame to detect keypoints in is masked by a star mask, which is a mask computed based thresholding the image for really bright spots and then dilating them bit.  This avoids letting SIFT grab keypoints from things like clouds.

Earth alignment is done with opencv2's AKAZE Algorithm.  Before alignment the image is boosted in a number of ways to allow at least the horizon area to allow keypoint detection, if not other parts of the foreground as well.

These alignments are based upon some number of detected control points, i.e the same feature in each frame.  How far away they are from eachother is used to calculate a transformation to all but the first image given in the stack to be aligned.

This means that for both static and moving tripod heads (any number of axes), Star is able to align one or more of the neighboring frames to each frame that Star is processing.  Typically there will be a very small area around the borders of the frame which have been rotated out.  In practice this is just a handful of pixels, and is not a problem.

The benefits of having aligned neighbor frames for each frame Star processes are:

 - a much more accurate subtraction image in step #3
 - more accurate data to replace unwanted pixels with

When using multiple aligned frames, Star applies the standard deviation of brightness between a given pixel position in each of them to determine if any of them contains a noisy value at that pixel.  This works best when aligning with more frames, which is slower.  I've found that 8 frames is a good number of frames to have aligned to each frame being processed.  This gives enough signal over the noise of artifical objects in the sky.

This parameter is configurable from a minimum of 1 to the ability of your machine to process lots and lots of data.  In theory the more aligned frames the better, except for machine overload and the fact that the ground moves further when aligning more frames.  This can be a problem for removing noise next to the horizon. 

The end result from this step is one or two aligned composite frames, one for the sky and maybe one for the earth.

Each one of these will have had most of the unwanted signal removed, the better signal to noise ratio happens when more images are processed.

### Step #3, image subtraction

The next step is to subtract the aligned image from the frame being processed.

This subtraction image is done in greyscale, and records the amount of change in brightness between the frame being processed and one of its neighboring frames.  If the neighbor has been aligned, then almost all of the bright changes in the sky are a result of things like airplanes.  Clouds can also change brightness levels, even with really dark skies, as they can reveal stars as they move.

The subtraction is really just taking each pixel value and subtracting the neibhoring frame's value for the same pixel.

As of Star v0.7.3, the subtraction image is calculated as a sum of all aligned images.  This has the effect of reducing the noise in the subtration image, allowing for detection of noisy pixels across more than one frame.  For example, if a set of pixels is illuminated in two neighboring frames by different but nearby sources, then the subtraction image from only that one other frame would not be able to distinguish that set of pixels as noisy.

With more subtraction images assembled into the subtraction image, we can more easily identify pixels in the frame being processed as undesirable noise.

As of Star v0.9.0, the subtraction image can be calculated from both the star aligned and earth aligned images if horizon detection is enabled.  This allows for detection of headlights, and recudes the number of false negative signals found on the ground.

### Step #4, detect groups of bright pixels in the subtraction image 

In the next step, Star sorts all of the pixels in the subtraction image from step #2 by brightness, brightess first.

Star then iterates, brightest pixel first, and looks for pixels around each bright pixel that are not too much darker.  This creates a potentially large number of groups of brighter pixels.

These are called `Blobs` in the Star code.

A first level of filter is done here, where we look back at the original image around the pixels which we have identified as part of each blob.  If the signal we're observing is because of a moving lighted object, then it is almost always the case that any nearby pixels in the original image are less bright than the pixels in the blob.

Other signals can show up in the subtraction image which do not follow this rule.  Moving landscape is one.  Partially, but not fully aligned bright stars are another.

So before being added to the initial list to blobs to consider, a quick check of nearby pixels on the original source image is performed, which can throw out nearly half of the blobs in many cases.

### Step #5, apply heuristics to filter out groups

In step #5, a set of heuristics is applied to the potentially large group of blobs from step #4.

This can be controlled the `--detection-type` command line argument.

Many of the smaller blobs that are not close to any other blos are removed here, as well as a number of other techniques.

Using different versions of `--detection-type` will result in more Blobs making it past this step.

This can drasticaly reduce the number of blobs present

### Step #6, use grouping and line detection to combine blobs

In these steps, nearby blobs are grouped together, and then some of them may be combined together if they are found to be linear, i.e. making a line.  Star uses the kernel hough transform to detect lines in blobs.

Many airplane signals close to the horizon are a sequence of separated dots.  This step tries to combine them into a single group, which conforms to a line we have found.

Combining these small dots at this step helps us to both categorize based upon linearity, and weed out smaller blobs after this that do not form a line.

### Step #7, throw out a lot of small, dimmer blobs

At this step, we assume that any blobs that are small and too dim can be thrown away.  This can really reduce the number of blobs per frame, from thousands to hundreds or less.

### Step #8, use machine learning to classify bright groups

At this point, what are called `Blob`s in the code are promoted to `OutlierGroup`s.

Each `OutlierGroup` is able to provide a list of classification criteria for itself.

Some of these are very basic, like the number of pixels, their brightness, the size of their bounding box, their position in the frame, etc.

Others are more complicated, involving things like the Kernel Hough Transform to attempt to detect lines.

Data from neighboring frames is used as well, things like how many pixels in frames close by are also an outlier at the same place.  Airplanes tend to streak across frames, not touching the same pixel twice in adjecent frames.

All of this data is fed into a machine learning system developed for Star, using decision trees.

For each `OutlierGroup`, the machine learning system will output a real number value between -1 and 1.  -1 means that Star should leave it alone.  1 means that Star should include the pixels from this `OutlierGroup` in the layer mask for step #3.  Zero is wholly unclear.  Any other value betwee -1 and 1 is a guess, multiply by 100 to get percentage.  Negative values mean likelyhood of leaving it alone.  Positive values mean the likeyhood of removing those pixels.

A set of images sequences can be validated as being 'correct' by fixing all of the classification errors using the Star gui application, frame by frame.  This can be tedious, but results in both an image sequence with as much unwanted signal removed as possble, as well as a 'validated' image sequence, which can be used to train the machine learning engine to produce more accurate decision trees.

Each version of Star has some set of decision trees embedded in it.  Currently the approach is to generate a 'forest' of trees, each using a slightly different set of test data.  Then a high level classifier combines all of their scores to get a consensus vote, which tends to increase accuracy by 0.5% or more.

As of Star 0.7.1, two levels of decision tree forests are used with different classification criteria.  The first level of classification does not rely upon other frames, only data from within the frame being processed is used for this level of classification.  We also accept a level less than zero to let more pass through.

Any blobs that fail this first level of classification are left in the trash bin.  Data in the trash bin can be recovered later if desired.

The second level of classification uses a super set of criteria from the first level, including information about outlier groups in neighboring frames.  If any data fails this level of classification it is shown in the gui as green, as opposed to the yellow trash bin.

Seperating out into two levels of classification allows us to deal with smaller groups of pixels more efficiently.  

This step is still a work in progess, specifically needing more training data, and potentially more classification criteria as well.

Best accuracy so far is approx 99.1% on test data.

Other approaches to machine learning are also possible, if I find time to pursue them.  So far I've been making the data more linear for easier classification. 

### Step #9, layer mask creation

After final classification of all the `OutlierGroup`s for the frame being processed, Star will then create a layer mask.

This 'layer mask' is used in the same way as a layer mask in an application like The Gimp or Photoshop.

The base image is the layer being processed.  On top of that is placed the (hopefully aligned) neighbor frame, using the layer mask created here to determine how much of each pixel from the aligned image to include in the final output.

Currently the layer mask is created by selecting all pixels that are part of `OutlierGroup`s that were scored positive by the machine learning engine.

Next this selection is enlarged by a handful of pixels, at full opacity, meaning that some number of pixels that were not part of any `OutlierGroup` are still fully changed in the output frame.

Then, the selection is feathered a larger amount of pixels.  During this feathering, the opacity of the layer mask decreases to zero at the edges.  This helps to avoid any rough changes when Star replaces pixels in the final output.

### Step #10, generate output image.

Given the layer mask from step #3, and the (hopefully aligned) neighbor frame from step #1, Star simply blends the desired pixels from the neighbor frame into the right places into the frame being processed.

If all has gone well with detection and classification for this frame, then the output image will not include the vast majority of unwanted airplane and satellite signals.

Still hard to detect as of Star 0.9.0, sorted by hardest to detect first:

 - really slow moving satellites
 - really dim satellites, even when moving fast





