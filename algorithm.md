# How ntar detects and removes airplane streaks from timelapse images

Here is a description of the algorithm used by ntar for airplane removal.

## Outlier Analysis

The first step is to analyze each frame with the frames next to it, and find pixels that are too bright, called outliers.

### Outlier Detection

To detect outlyling pixels on each frame, each frame from the video sequence is processed with one or two adjecent frames.

Only the first and last frames are processed with only one adjecent frame.

To identify outlying pixels, each pixel on a frame is compared with the same pixel on adjecent frames.  If the brightness level increases by more than a given threshold (given by the -b command line option), then that pixel is considered to be an outlier.  While outlier pixels can occur wihtout being caused by airplanes, all airplane produce outlier pixels.

### Outlier Grouping and Analysis

Next these outliers are gathered into groups of direct neighbors, ignoring groups that are too small (given by the -m command line option).  If too many small groups are processed, running time can get really long.

Then each identified outlier group is categorized as either likely an airplane or not, based upon a number of criteria.

A Hough Transform is run on each outlier group separately from the rest of the image.  The resulting list of lines is part of the analysis.

In addition, the size of each outlier group, the number of pixels it fills within its bounding box (fill rate), the aspect ratio of its bounding box, and the brightness level of the group compared to the adjecent frames are all included.

This set of data about each outlier group is then ranked based upon histograms generated from data via the outlier data process outlined in outlier_data_process.txt.  More data here is always helpful.

## Inter Frame Analysis

Outlier detection and analysis is embarassingly parallel, i.e. each can be done separately, with no dependency on eachother.  The same is not true of inter frame analysis, which comes next.

Inter frame analysis compares the outlying groups in frames across a wider range of frames, and uses the presence of absence of outlier groups in other frames to determine the paintability of groups in a particular frame.

### Streak Detection

The main point of inter frame analysis is to improve the false positive and netagives from the previous outlier group histogram analysis by looking for outlier groups that move in streaks.

A Streak is defined to be outlier groups that are moving in the same direction as the lines that descirbe them.  Most airplanes will be captured in more than one frame.  If not, it's likely to be a very large outlier group, which will get painted over because of its size.

Streak detection can help find smaller outlier groups closer to the horizon that are of a smaller size.  It can also help to find outliers that aren't airplanes, but did get marked so by the previous analysis.

## Final Processing

After the final paintability of each outlier group has been decided for a particular frame, it is then put into a final queue which handles painting over the identified airplane streaks, and saving the output file.

Painting over airplanes is done by simply copying pixels from one of the adjcent frames.

## Further Work

While Ntar does get most airplane streaks, it doesn't get them all.

Further work may include identifying outlier groups in a single frame that are small, but that confirm to a line.  Some airplane streaks are not in a single group, but a group of groups placed close to eachother.

Another issue that needs to be addressed are false positives on the horizon for non-static timelapses, i.e. when captured on a moving head and / or slider.  Sometimes features of the horizon are linear enough to get marked as airplanes, and end up causing the horizon to visibly jump a bit sometimes.  One possible solution to this would be to notice a brightness difference on opposite sides of the outlier group, and disable painting based upon that criteria.

A helpful feature of ntar for debugging is the test-paint mode (-t command line option).  This will output a separate image sequence which paints over outlier groups with colors (-s command line option describes them) that will tell you why or why not an outlier group was or was not painted over.

Also more speed and memory usage improvements are always a good thing.