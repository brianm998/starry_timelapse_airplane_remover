import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// load and process all blobs for a frame, using a defined sequence of steps
public class ExcessiveBlobProcessor: AbstractBlobProcessor {

    override public init() {
        super.init()
        self.steps = [

          .findBlobs(.init(minPixelIntensity: 6000,
                           startContrastSize: 10,
                           endContrastSize: 50,
                           startMinContrast: 86,
                           endMinContrast: 86)),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          
          .frameState(.filter1),

          .houghLineMatrixBlobConnector(.init(elementWidth: 600,
                                              elementHeight: 400,
                                              overlapPercent: 20,
                                              maxHoughLines: 2000,
                                              sideIterationPixels: 5,
                                              maxBlobDistance: 30)),

          .save(.filter1),
          .frameState(.filter2),

          // reconnect some lines that may have been split up
          .linearBlobConnector(.init(scanSize: 12, 
                                     blobsSmallerThan: 6800,
                                     lineBorder: 8)),

          .save(.filter2),
          .frameState(.filter3),

          // try to combine lines in another way
          .linearBlobExtender(.init(minBlobSize: 30,
                                    lineExtension: 25,
                                    innerSearch: 15,
                                    maxIterationCount: 4,
                                    scoreMultiplier: 8.1,
                                    sideIterationPixels: 5)),

          .save(.filter3),
          .frameState(.filter4),


          .compactBlobIds,
          
          .save(.filter4),
          .frameState(.filter5),
          
          .blobLineTrim(.init(minBlobSize: 40,
                              minLineLength: 30,
                              minLineFillAmount: 10,
                              trimAmount: 9)),

          .save(.filter5),
          .frameState(.filter6),

          .save(.filter6),
          .frameState(.filter7),
           
          .compactBlobIds,

          .save(.filter7),
          .frameState(.filter8),
          
          // split up blobs based upon user input
          .applyUserSlices,

          .save(.filter8),

          /*

          .frameState(.filter9),
           
          .save(.filter9),
          .frameState(.filter10),


          .save(.filter10),
          .frameState(.filter11),


          .save(.filter11),
          .frameState(.filter12),
            

          .save(.filter12),
          .frameState(.filter13),


          .save(.filter13),
          .frameState(.filter14),

          .save(.filter14),
          .frameState(.filter15),

          .save(.filter15),
          .frameState(.filter16),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
          
           */
        ]
    }
}
