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
                           endMinContrast: 0)),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("init"),

          .save(.blobs),          
          .frameState(.filter1),

          .houghLineMatrixBlobConnector(.init(elementWidth: 600,
                                              elementHeight: 400,
                                              overlapPercent: 30,
                                              maxHoughLines: 2000,
                                              lineIterationPixelRaius: 0,
                                              maxBlobDistance: 30)),
          
          .save(.filter1),
          .frameState(.filter2),



          // reconnect some lines that may have been split up
          .linearBlobConnector(.init(scanSize: 40, 
                                     blobsSmallerThan: 680,
                                     lineBorder: 2)),

          .save(.filter2),
          .frameState(.filter3),

          // reconnect some lines that may have been split up
          .linearBlobExtender(.init(lineExtension: 15,
                                    innerSearch: 10,
                                    adjecentPixelsOnIteration: 5,
                                    maxIterationCount: 20)),

          .save(.filter3),
          .frameState(.filter4),

          .borderBrightnessBlobRemover(.init(maxBrightness: 0.65,
                                             medianIntensityFloor: 10000)),

          
          .save(.filter4),
          .frameState(.filter5),

          // a first pass on dim isolated blob removal
          .dimIsolatedBlobRemover(.init(scanSize: 80,
                                        requiredNeighbors: 1,
                                        intensityFloor: 5000)),

          .save(.filter5),
          .frameState(.filter6),

          // remove isolated blobs
          .isolatedBlobRemover(.init(minNeighborSize: 4,
                                     scanSize: 50)),
          

          .save(.filter6),
          .frameState(.filter7),

          
          // remove smaller disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 18,
                                         requiredNeighbors: 2,
                                         intensityThreshold: 15000)),

          .save(.filter7),
          .frameState(.filter8),

          .isolatedBlobRemover(.init(minNeighborSize: 4,
                                     scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),

          .save(.filter8),
          .frameState(.filter9),

          .largeDimBlobCleaner(.init(minBlobSize: 5000,
                                     intensityFloor: 1000)),


          .save(.filter9),
          .frameState(.filter10),


          // another pass at cutting out individual blobs based upon size, brightness
          .trimWithConstants(.init(minBlobSize: 10,
                                   minBlobIntensity: 1000,
                                   qualifierSize: 18,
                                   qualifierMedianIntensity: 10000)),


          .save(.filter10),
          .frameState(.filter11),

          
          // pass on getting rid of small dim blobs
          .smallBlobRemover(.init(minBlobSize: 6,
                                  intensityFloor: 1000)),

          .save(.filter11),
          .frameState(.filter12),
            
          // pass on getting rid of small but larger, dimmer blobs
          .dimIsolatedBlobRemover(.init(scanSize: 80,
                                        requiredNeighbors: 2,
                                        minBlobSize: 24,
                                        intensityFloor: 5000)),

          .save(.filter12),
          .frameState(.filter13),


          .smallDimBlobRemover(.init(minBlobSize: 4)),
          
          // pass on getting rid of small but larger, dimmer blobs
          //.smallBlobRemover(.init(minBlobSize: 10)),

          .save(.filter13),
          .frameState(.filter14),


          // a final pass at isolated removal
          .isolatedBlobRemover(.init(scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 30)),
          

          .save(.filter14),
          .frameState(.filter15),
          
          // split up blobs based upon user input
          .applyUserSlices,
          
          // any really big blobs with lots of small bunches that are dim can go away
          .removeReallyBigBlobsWithSmallDimBunches(.init(minBlobSize: 1000,
                                                         minBunchCount: 100,
                                                         maxBunchSize: 10,
                                                         intensityCeiling: 6000,
                                                         removePixelsDimmerThan:  6000)),

          .save(.filter15),
          .frameState(.filter16),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .nonLinearBlobRemover(.init(lengthOverFillAmount: 10)),

          .save(.filter16),
        ]
    }
}
