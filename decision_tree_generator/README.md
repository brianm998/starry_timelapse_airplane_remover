# decision tree generator

This package produces a binary which is able to learn from a structured data set of outlier group data and then produce a classifier which attempts to classify new data.

## Outlier Groups

Outlier Groups are groups of outlying pixels in the frame of a timelapse.  Outlying pixels are slightly brighter than the same pixel positions on the frame before and after it.  Groups of adjecent outlying pixels are called outlier groups.

In general, outlier groups can arise in a video for lots of different reasons.  Car headlights are a good way to for this to happen.

In night time timelapses of the night sky, airplanes and satellites show up as a row of outlying pixels.  Stars and clouds can also show up as outlier groups, as well as any driving cars that might be in frame.

## Classification

The current set of classifiers is based upon a set of clasification features that have been coded manually.  Things like size, screen position, and lots more.

A structured data set is generated via the star gui, where the user manually fixes all the false positive and negative results from a previous classifier.   

This data set is digested by this module to generate on or a set (forest) of trees, each one of which can classify an outlier group with a value between -1 and 1, where 1 is something to remove (airplanes, satellites, etc) and -1 is something to leave in place (stars, clouds, etc).

