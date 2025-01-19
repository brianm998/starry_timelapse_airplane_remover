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

          .findBlobs(.init(minPixelIntensity: 6000,
                           startContrastSize: 10,
                           endContrastSize: 200,
                           startMinContrast: 60,
                           endMinContrast: 40)),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),
        
          .save(.blobs),          

          .frameState(.filter1),


          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 16, 
                                     blobsSmallerThan: 120,
                                     lineBorder: 12)),


          .save(.filter1),

          .frameState(.filter2),

          .save(.filter2),

          .frameState(.filter3),
          
          // a first pass at cutting out individual blobs based upon size, brightness

          .save(.filter3),
          
          .frameState(.filter4),
          // a first pass on dim isolated blob removal

          // remove isolated blobs

          .save(.filter4),
          .frameState(.filter5),

          // remove smaller disconected blobs
          .save(.filter5),
          
          .frameState(.filter6),
          // find really close linear blobs
          .save(.filter6),

          .frameState(.filter7),
          // remove larger disconected blobs
          .save(.filter7),


          .frameState(.filter8),
          .save(.filter8),

          .frameState(.filter9),

          // try to do more line adjustment after removing some isolated blobs

          .save(.filter9),

          .frameState(.filter10),
          
        
          .save(.filter10),

          // try to split up blobs with more than one line in them

          .frameState(.filter11),

          .blobLineTrim(.init(minBlobSize: 40,
                              minLineLength: 30,
                              minLineFillAmount: 10,
                              trimAmount: 9)),

          .save(.filter11),
          
          .frameState(.filter12),
          
          .save(.filter12),

          .frameState(.filter13),

          .save(.filter13),
          
          .frameState(.filter14),
          
          // split up blobs based upon user input
          .applyUserSlices,

          .save(.filter14),

          .frameState(.filter15),
          
          
          .save(.filter15),
        
          .frameState(.filter16),
          
          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
        ]
    }
}
