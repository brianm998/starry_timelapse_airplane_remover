
# Nighttime Timelapse Airplane Remover

This is a command line utility that removes airplanes streaks from night time timelapse videos.

It operates upon a still image sequence, and outputs a modified sequence which can be then rendered into a video with ffmpeg or other software.  It has been designed as part of a post processing workflow, so it currently only operates on 16 bit tiff still image sequences, not rendered videos directly.

The purpose is to remove airplane and satellite streaks from overnight timelapse videos.  These can be distrating to viewers, who often assume them to be 'shooting stars', because the move so fast in a timelapse.  For years I've accepted airplanes in the night sky in my timelapses, and even like them you can see the airplanes landing in an airport.  But when out in really dark skies in the middle of nowhere, IMO the airplanes stick out too much.

Be aware that incoming meteor trails will be caught as well, best to re-introduce those from the original video in post if you want to keep them.

Ntar is written in swift, and uses only the Foundation, CoreGraphics and Cocoa frameworks.  Any swift installation that has these frameworks should be able to compile and run this software.  I've developed it on macos, and can provide binaries for any desktop mac architecture.  It _might_ compile on windows and or linux, let me know if it works for you.

Under development, feel free to reach out to me if you have any questions.

