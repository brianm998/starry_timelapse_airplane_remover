import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// load and process all blobs for a frame, using a defined sequence of steps
public class StrongBlobProcessor: AbstractBlobProcessor {

    override public init() {
        super.init()
        
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
                           startMinContrast: 70,
                           endMinContrast: 40)),

          
          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          

          .frameState(.filter1),


          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 12, 
                                     blobsSmallerThan: 180,
                                     lineBorder: 12)),


          .save(.filter1),

          .frameState(.filter2),

          .save(.filter2),
          .frameState(.filter3),
          
          
          .save(.filter3),
          .frameState(.filter4),

          .save(.filter4),
          .frameState(.filter5),
          
          .save(.filter5),
          .frameState(.filter6),

          .save(.filter7),
          .frameState(.filter8),
          .save(.filter8),
          .frameState(.filter9),

          .save(.filter9),
          .frameState(.filter10),
          


          .save(.filter10),
          .frameState(.filter11),

          .save(.filter11),
          .frameState(.filter12),

          // try to split up blobs with more than one line in them


          .blobLineTrim(.init(minBlobSize: 40,
                              minLineLength: 30,
                              minLineFillAmount: 10,
                              trimAmount: 9)),

          .save(.filter12),
          .frameState(.filter13),
          

          // a first pass at cutting out individual blobs based upon size, brightness
          
          // pass on getting rid of small but larger, dimmer blobs
          // XXX this needs to take into account distance from others, it's killing us
          //.smallBlobRemover(.init(minBlobSize: 50,
          //intensityFloor: 7500)),
          .save(.filter13),
          .frameState(.filter14),

          // pass on getting rid of small but larger, dimmer blobs
          //.smallBlobRemover(.init(minBlobSize: 10)),

          .save(.filter14),
          .frameState(.filter15),


          
          // split up blobs based upon user input
          .applyUserSlices,

          .save(.filter15),
          .frameState(.filter16),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
        ]
    }
}
