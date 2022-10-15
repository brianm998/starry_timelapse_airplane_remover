
# Nighttime Timelapse Airplane Eraser

This is a command line utility to remove airplanes from night time timelapse videos.

It operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.

It is written in swift, and uses only the Foundation, CoreGraphics and Cocoa frameworks.  Any swift installation that has these frameworks should be able to compile and run this software.

The algorithm used looks for differences in color and brightness levels between pixels in adjecent video frames.  If enough outlying pixels are found next to eachother, they are then painted over with a blend of the data from the adject frames.  Satellites and other smaller items are harder to catch.

Under development, feel free to reach out to me if you have any questions.