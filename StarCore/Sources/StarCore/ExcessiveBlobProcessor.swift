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

          .findBlobs(.init(minPixelIntensity: 4000,
                           minContrast: 86)),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          

          .frameState(.filter1),


          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 32, 
                                     blobsSmallerThan: 180,
                                     lineBorder: 12)),


          .save(.filter1),

          .frameState(.filter2),

          .borderBrightnessBlobRemover(.init(maxBrightness: 0.5,
                                             medianIntensityFloor: 10000)),

          .save(.filter2),

          .frameState(.filter3),
          
          // a first pass at cutting out individual blobs based upon size, brightness
          .trimWithConstants(.init(minBlobSize: 15,
                                   minBlobIntensity: 1000,
                                   qualifierSize: 10,
                                   qualifierMedianIntensity: 3500)),

          .save(.filter3),
          
          .frameState(.filter4),
          // a first pass on dim isolated blob removal
          .dimIsolatedBlobRemover(.init(scanSize: 80,
                                        requiredNeighbors: 1,
                                        intensityFloor: 5000)),
          
          .save(.filter4),
          .frameState(.filter5),

          // remove isolated blobs
          .isolatedBlobRemover(.init(minNeighborSize: 4,
                                     scanSize: 50)),
          
          .save(.filter5),
          .frameState(.filter6),
          
          // remove smaller disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 18,
                                         requiredNeighbors: 2,
                                         intensityThreshold: 15000)),
          
          // find really close linear blobs
//          .linearBlobConnector(.init(scanSize: 32,
//                                     blobsSmallerThan: 180,
//                                     lineBorder: 12)),

          .save(.filter6),

          .frameState(.filter7),

          // remove larger disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 18,
                                         blobsLargerThan: 2,
                                         requiredNeighbors: 2)),
          .save(.filter7),
          .frameState(.filter8),
          
          .isolatedBlobRemover(.init(minNeighborSize: 4,
                                     scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),
        
          .save(.filter8),
          .frameState(.filter9),

          // try to do more line adjustment after removing some isolated blobs
//          .linearBlobConnector(.init(scanSize: 32,
//                                     blobsSmallerThan: 180)),


          
          .isolatedBlobRemover(.init(scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),

          // try to split up blobs with more than one line in them

          .save(.filter9),
          .frameState(.filter10),

          // this appears to be slow
          .lineSplit(.init(minAvgDistance: 5,
                           maxLineFillAmount: 0.5,
                           minBlobsize: 500,
                           maxLines: 8000,
                           maxDistance: 12,
                           minLineScore: 12,
                           minLineCount: 10)),

          .save(.filter10),
          .frameState(.filter11),

          // blob line trim
          .blobLineTrim(.init(minLineLength: 65,
                              minLineFillAmount: 0.9,
                              trimAmount: 16)),

          // reconnect some lines that may have been split up
          .linearBlobConnector(.init(scanSize: 40, 
                                     blobsSmallerThan: 180,
                                     lineBorder: 2)),

          .save(.filter11),
          .frameState(.filter12),
          
        
          // pass on getting rid of small dim blobs
          .smallBlobRemover(.init(minBlobSize: 6,
                                  intensityFloor: 1000)),

          .save(.filter12),
          .frameState(.filter13),

            
          // pass on getting rid of small but larger, dimmer blobs
          .dimIsolatedBlobRemover(.init(scanSize: 80,
                                        requiredNeighbors: 2,
                                        minBlobSize: 24,
                                        intensityFloor: 5000)),

          .save(.filter13),
          .frameState(.filter14),

          .smallDimBlobRemover(.init(minBlobSize: 4)),
          
          // pass on getting rid of small but larger, dimmer blobs
          //.smallBlobRemover(.init(minBlobSize: 10)),

          .save(.filter14),
          .frameState(.filter15),


          // a final pass at isolated removal
          .isolatedBlobRemover(.init(scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 30)),
          
          
          // split up blobs based upon user input
          .applyUserSlices,

          .save(.filter15),
          .frameState(.filter16),
          
          // any really big blobs with lots of small bunches that are dim can go away
          .removeReallyBigBlobsWithSmallDimBunches(.init(minBlobSize: 1000,
                                                         minBunchCount: 100,
                                                         maxBunchSize: 10,
                                                         intensityCeiling: 6000,
                                                         removePixelsDimmerThan:  6000)),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
        ]
    }
}
