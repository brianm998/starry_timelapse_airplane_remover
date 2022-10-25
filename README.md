
# Nighttime Timelapse Airplane Remover

This is a command line utility to remove airplanes from night time timelapse videos.

It operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.  

It attempts to identify objects such as airplane trails and remove them from the video.  Low flying airplanes that leave big streaks are easily detected.  High flying planes, even close to the horizon are more difficult.  Some sattelites may be detected, but many are not.  Be aware that incoming meteor trails will be caught as well, best to re-introduce those from the original video in post currently.

It is written in swift, and uses only the Foundation, CoreGraphics and Cocoa frameworks.  Any swift installation that has these frameworks should be able to compile and run this software.

Each video frame is compared to the frames immediately before and after it.  For the first and last frame, this means there is only one other frame to compare to.  Based upon a provided brightness threshold, a number of 'outlier' pixels are identified in the frame being processed.  These pixels are brighter than those at the same image position in the adjecent frames.  The brightness level used is a max of the total brightness level and each of the r,g,b channels. 

After identifying a set of outlier pixels for the processed frame, groups of outlier pixels are identified by thier immediate proximity.

After grouping the outliers, each group is categorized as either paintable or not by some criteria.  This painting is done by replacing the offending pixels with the value of the same pixel from the adjecent frames.  If only one frame is present, it's a simple copy.  For all but the first and last frames, outliers are painted over with an average of the values of the two adjecent frames.

Initially determination of whether of not a group was going to be painted over was concerned with only group size, using a threshold to determine whether to print over them or not.  While this did work for getting rid of the biggest airplane streaks, there was a grey area where lowering the threshold too much caused non-airplane objects to get painted over too.

The next iteration was to establish a bounding box for each outlier group, i.e. the smallest crop of the image that could contain all outlying pixels in that group.  A threshold is then applied to the distance between the corners of the group, and only bounding boxes above this threshold are painted over.  This gets better at detecting lines of outliers apart from more circular blobs.

The next iteration was to develop a Hough Transform class which is able to identify lines in a dataset.  Initially this dataset was a matrix of boolean values for each pixel, set to true when there was an outlier group with a size greater than some value.

This identified each line in the outlier data set, and was able to identify catch many airplanes.  The recoginition method was initially based upon just what lines the bounding box would make from its diagionals.  Good enough at first, but many stars that happened to be in line with actual airplane tracks started getting painted.

The next iteration was to classify the theta and rho (polar line coordinates) for each outlier group separately.  This requires running the hough transform separately on each outlier group, but is able to properly distinguish if there is any line orientiation in each group of outliers.

Future iterations could involve testing and tweaking some constants more, as well as implementing some speed improvements in the many many hough transforms needed.

Under development, feel free to reach out to me if you have any questions.