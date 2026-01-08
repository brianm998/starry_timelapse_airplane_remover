# This document describes the algorithm used by Star to remove airplanes and satellites from image sequences

Written as of Star 0.10.4

## High Level

Star offers to different and complementary methods to remove unwanted signals from timelapses.

 - Auto Clean
 - Selective Clean

Auto Clean can be used by itself, or in addition to selective clean in one of two ways:

 - to select which identified bad signals to remove from the original image
 - to select which identified good signals to retain in the fully processed image

### Auto Clean

Auto Clean is used by all processing modes, but in potentially different ways.

The goal of auto clean is to automatically remove all artificial lights that are moving from the video.  This can include both sky and earth.

The output image has had every single pixel potentially updated, using the following sequence of steps.

If Auto Clean is the desired clean mode, then the output image will be simply the auto cleaned frame.

If using either of the selective modes, then the output image will include some parts or almost all of the auto cleaned frame.

#### Horizon Detection

First, if a video contains both sky and earth, Star needs to detect the horizon.  This is necessary for both proper alignment of the sky and maybe the earth.  It is also necessary when outputting an auto cleaned frame.

To detect the horizons Star uses a combination of Otsu classification, connected component filtering, and Canny edge detection.

As of Star 0.10.4, horizon detection works best on darker horizons.  If the moon is up, or there is snow on the horizon, or lots of clouds, then horizon detection will not work as well.

In those cases, selective clean may work better, as it doesn't depend as much on good horizon detection.

#### Star Alignment

Star Alignment is how Star computes a frame that doesn't contain any satellites or airplanes.

At the core, some number of neighboring frames are aligned with each frame being processed.

The default setting of 8 neighbor frames (four on each side) seems to work pretty good.

First the frame being processed has keypoints identified in it using SIFT (Scale Invariant Feature Transform) in opencv.  A layer mask that disregards the earth and areas that are not close to bright stars is used to make sure we're aligning with the movement of the stars and not clouds or the earth.

Then each neighboring frame has keypoints identified, and then matched with the keypoints of the using a number of different feature matching methods in opencv.

If anough keypoints can be matched, then a 3x3 matrix of homography is be computed which can be used to warp the neighboring frame to match the frame being processed.

Each 3x3 matrix of homography tells the warper to deviate the frame being warped by an average number of pixels, which can be computed as an average deviation for each frame from not being warped at all.  

A 'good' alignment of all eight neighboring frames results in deviations for each neighbor frame which are multiples of a deviation of the nearest frames, within some bounds.

That means that a neighbor frame 2 frames away has been warped twice as much as a frame directly adject (1 frame away).

Star accepts neighboring frame warps that are close to all having the same amount of deviation per frame distance, regardless of how much that warp ends up being.

If for whatever reason Star cannot get all neighbors to look like they are aligned properly, it will take a second pass on aligning frames.

This second pass will re-warp any initial warps that didn't look properly aligned.  Star will re-warp them with the homograpy from the nearest frame that did have good warping.

Conditions where this is necessary include dawn and dusk, as well as frames with lots of clouds.

If a video was captured on a static tripod, then the homography from other frames is likely to be very good.

If a video was captured on a moving tripod head, then the homography from other frames won't be 100%, but for dawn/dusk/lots of clouds, it's good enough.

##### Median Merge

After successfully aligning all the desired neighor frames, Star will then proceed to merge them into a single image my choosing the median intensity for every channel of each pixel.

What this means is that Star will collect all of the values for each pixel, and sort them by brightness.  Zeros values are ignored, they may come from parts of an image that had no signal after warp.  In addition, values that are statistically too much brigher than the other values for that pixel are ignored.  Then the median value remaining in the list sorted by intensity is chosen.

This is a very similar process to how deep sky astrophotography can be done.

The median merge is similar, but different from simply merging all of the values together.

Specifically it throws out all of the bright signal, where a mean merge (average) would include all pixels in the final output.  While a mean merge does reduce the brightness of unwanted pixels, the signal will still be present.  Using the median (value in the middle) throws out the bright pixels like it throws billionares out of financial numbers. 

Be aware that clouds will look different, appearing to flow a bit smoother.  Whether clouds look better or worse with this teatment is a matter of taste.

#### Earth Alignment

##### Static

For videos shot on a static tripod, earth alignment works well.  This uses the same logic as star alignment above, just minus the keypoints and warping, only doing the median merge.

This can help to get rid of highlights from moving cars, and also to allow the horizon mask to be median merged over neighbors, giving a better result for difficult horizons.

It is also helpful to have an earth aligned image to get rid of bad airplane signals right on the horizon.  In this case, the earth aligned image will include the sky, which looks very similar to the sky aligned image, but with most of the stars blurred out.  Star has a parameter which allows a certain amount of the earth aligned image to be used directly above the horizon.

The benefit of using some of the earth aligned image in the sky is that airplanes will not appear right next to the horizon as they might sometimes otherwise do.  The negative is that stars will be blurred out right next to the horizon as well, but not for long.

##### Moving

For videos show on a moving triod, earth alignment is experimental as of Star 0.10.4.  There is an option in settings to turn it on, off by default.   

It needs more work, as earth alignment is more difficult, especially for really dark foregrounds.

#### Final Auto Clean

If using auto clean, Star will then use the star aligned image for each frame, along with the horizon mask and earth image if present.

Auto clean simply does the same logic that photoshop uses for merging two layers with a mask.

This works well for users that don't want any airplanes or satellites in their videos.

Auto clean also gets rid of all meteors and any potentially associated explosions.

If a user wants to keep any of these signals in their video, they should choose selective clean or selective auto clean.

The introductory UI is designed to make this as intuitive as possible.

### Selective Clean

Selective clean is good if users want to get rid of the most obvious and blaringly bright airplane and satellite signals, and leave the rest.

Selective clean is also good if users want to keep meteor streaks.  If users want meteors without any satellites, then selective auto clean is better than selective clean.

Selective Clean starts with the final auto clean image for each frame.

It then:

1. subtracts the auto clean image from the frame being processed
2. detect bright groups of pixels in the image from step #1
3. apply some heuristics to filter out a lot of the groups from step #2
4. use grouping and line detection to combine lines of dots
5. throw out a lot of smaller groups
6. classify groups left after step #7 using machine learning to decide which ones to derive layer masks from
7. create a layer mask for this frame using the classified groups from step #6
8. use the layer mask from step #7 and the aligned neighbor frames to generate the output image for this frame

This ends up giving the user with a list of identified areas of each frame that could be removed.  If an area is identified for removal, either through automatic classification, or via user input, then that part of the output image is written out from the auto clean image.

This process preserves more of the original video content than the auto clean method.  Clouds should look the same as before.  Only the parts that are identifed to be removed are changed.

However, this requires more attention to each frame, and can be time consuming. 

### Selective Auto Clean

Selective Auto Clean is basically Selective clean but flipped so that the base image being output is the Auto Clean image, instead of the original image being processed.

This allows users to get rid of all bad signals except for a very few desired ones.

One use case for this is meteors.  As of Star v0.10.4 there is no classification into meteor/airplane/satellite/other, just a binary good/bad.

A future feature would be to widen the ability to classify into more categories.




