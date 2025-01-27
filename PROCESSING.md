# How does the Starry Timelapse Airplane Remover work?

This is a detailed description of how the Starry Timelapse Airplane Remover, or Star, works.

At a high level, it looks at each frame in a video and compares it with neighboring frames.

Areas that are brighter in the frame being processed are analyzed further, using machine learning to determine what parts of the frame are not desired.

After classification, the undesired areas of each frame are replaced with data from a neighboring frame.

The Star App allows users to update the decisions, and those updates can be then fed into the machine learning engine to better train the classifiers.

## List of steps:

- Star Alignment
- Subtraction Image
- detect blobs
- detect lines of blobs
- apply first machine learning classification, producing dustbin
- apply second maching learning classification, determine painting
- create paint mask
- apply aligned frame with mask to original image
- verify and edit with Star App

### Star Alignment

The first step is to attempt to align the stars between the frame being processed, and a neighboring frame.

While Star will work without this step, it greatly improves the quality of the results.

Hugin's align_image_stack utility is used to align the neighboring frame with the frame being processed.  The neighboring frame is ideally distorted slightly, so that the stars are more closely aligned with those on the frame being processed.

If this works, the ground is rotated slightly as well.

The benefits of this step are that the subtraction image produced by the next step is a lot cleaner.  Most, if not all, stars in the aligned image will be very close in position to the same star in the frame being processed.  The greatly reduces the noise level during processing.

If this step fails for whatever reason, Star will fall back to using the neighboring frame without alignment.  Obvious bright airplanes should still be caught in this case.

### Subtraction Image

After producing a star aligned image, the next step is to simply subtract this from the frame being processed.

Each frame is reduced to 16bit grayscale, and then for each pixel, we take the value from the original frame, and subtract the value from the neighboring frame from that.

This has the effect of making airplane streaks stand out as bright lines.  Either as a single streak, or as a line of dots.

### Detect blobs

The next step is to detect blobs of neighboring pixels that are bright in the subtraction image.

Before proceeding further we first sort all pixels in the subtraction image by brightness.

We then look at the brightest pixel first, and group it together with any pixels next to it that aren't too dim.

At the end of this step, we will have detected a lot of changes between the frame being processed and its neighbor.  Some of these changes we wish to keep, some of these changes, we wish to remove.

### Detect lines in blobs

Given a large set of blobs for a frame, the next step is to apply a lot of line detection steps, all different applications of the Hough Transform.

This allows many linear features to be combined into a single blob.  Doing this makes the classification more accurate.

### Apply first machine learning classification, producing dustbin

The next step is to apply the first step of machine learning classification to the large set of blobs in the frame we're processing.

The first step uses a set of decision trees trained on classification features for each group which do not involve other groups in the frame being processed, or in other frames.

This classification is handled gently, i.e. values slightly below 0 are still condiered ok.

This decimates the list of blobs, throwing the remainder into the 'dustbin'.

The 'dustbin' is a collection of information which _probably_ is not wanted.

The user can pull data back from here later if desired.

### Apply second maching learning classification, determine painting

The next step is to apply a second decision tree to the remaining blobs.  This decision tree uses a superset of classification features from the first one, adding new features which look for other groups within the same frame, and neighboring frames.

The dustbin is ignored for this level of classification.

Most airplane streaks cover more than one frame, oftentimes with similar linear features.  I.E. they are in a line.

After this classification is used to determine which groups are 'painted over'.

### Create paint mask

All groups of pixels that have been classified as 'paintable', are then used to create a paint mask for the frame being processed.

This is treated similarly to a layer mask in image editing applications.

This mask includes all pixels identified by the above steps, plus a bit of a border, then a small amount of fade with transparency at the edges.

### Apply aligned frame with mask to original image

After we have a paint mask, we create a new image which is the result of the star aligned image masked by the paint mask, overlaid upon the frame being processed.

Ideally the result is that all of the airplane and satellite streaks have been removed, and the user can see the night sky as our ancestors saw it before modernity, sped up a bit.

Star is still a work in progress, and the classifications are not 100%.

### Verify and edit with Star App

Whether the image sequence was processed with the star command line application, or the Star App gui application, it's always a good idea to verify the results in the Star App before rendering the resulting video.

The Star App can playback the video with previews, where most issues will show up.

Dropping into edit mode in the Star App you should be able to fix any issues that might show up.