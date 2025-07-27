import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 problems:

  - line split on real lines can split them when it shoudln't
 
 */

// load and process all blobs for a frame, using a defined sequence of steps
public class MildBlobProcessor: AbstractBlobProcessor {

    override public init() {
        super.init()

        /*

         Next steps after moving border brightness outside of the FullFrameBlobber
         and into a new OutlierGroup classification feature:


         develop a working lineTrim() method for Blobs

         use things like line length, median distance from line, etc
         to figure out if line based trimming makes sense for each blob

         if the percentage of blobs anywhere the line is low, then don't touch it

         if there is a calculated line which goes very close to more than half
         of the pixels, then remove the farthest 10% that are more than X pixels
         from the line, then iterate again by re-calculating the line and trying again

         Keep track of all of these removed pixels, and try to see if there is another
         line to be found within.  Can help for cases with airplanes close to horizon



         
         use linear blob connector on larger blobs like before
         
         */

        

        
        /*
         Outlier Detection Logic is defined by the following set of steps

         starting with:
         
          - align neighboring frame
          - subtract aligned frame from this frame
          - sort pixels on subtracted frame by intensity
          - detect blobs from sorted pixels

          with lots of steps in the middle to refine the list of blobs

          ending with:
          
          - save image of final blobs before promotion to outlier groups
          - promote remaining blobs to outlier groups for further analysis
         */




        self.steps = [

          // initial detection of blobs from subtraction image
          .findBlobs(.init(minPixelIntensity: 8000,
                           startContrastSize: 10,
                           endContrastSize: 200,
                           startMinContrast: 60,
                           endMinContrast: 40)),

          
          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          
          .frameState(.filter1),

          // use hough line detection to identify lines and connect blobs along them
          .houghLineMatrixBlobConnector(.init(elementWidth: 600,
                                              elementHeight: 400,
                                              overlapPercent: 20,
                                              maxHoughLines: 2000,
                                              sideIterationPixels: 5,
                                              maxBlobDistance: 30)),

          .frameState(.filter2),


          // connect nearby blobs that are linear but still separate
          .linearBlobConnector(.init(scanSize: 10, 
                                     blobsSmallerThan: 6800,
                                     blobsLargerThan: 20,
                                     lineBorder: 15,
                                     minLineScore: 35,
                                     adjecentPixelsOnIteration: 5)),


          .frameState(.filter3),
          
          // try to combine lines in another way
          .linearBlobExtender(.init(minBlobSize: 30,
                                    lineExtension: 25,
                                    innerSearch: 15,
                                    maxIterationCount: 4,
                                    scoreMultiplier: 8.1,
                                    sideIterationPixels: 5)),




          .frameState(.filter4),

          .compactBlobIds,
          
          
          .blobLineTrim(.init(minBlobSize: 40,
                              minLineLength: 30,
                              trimAmount: 9)),
          .frameState(.filter5),


          .smallBlobRemover(.init(minBlobSize: 20,
                                  intensityFloor: 6000)),

          .frameState(.filter6),
          
          .compactBlobIds,

          .frameState(.filter7),
 
          // split up blobs based upon user input
          .applyUserSlices,
        ]
    }
}
