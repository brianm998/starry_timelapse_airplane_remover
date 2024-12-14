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

    override public init(frame: FrameAirplaneRemover) {
        super.init(frame: frame)

        self.steps = [

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

          .borderBrightnessLessThan(0.6),

          .save(.filter2),

          .frameState(.filter3),
          
          // a first pass at cutting out individual blobs based upon size, brightness
          // or being too close to the bottom

          .process() { blobs in
              var ret: [UInt16: Blob] = [:]

              for (_, blob) in blobs {
                  // anything this small is noise

                  let blobIntensity = await blob.medianIntensity()
                  
                  if await blob.size() <= constants.blobberMinBlobSize,
                     blobIntensity < 24000 // XXX constant
                  {
                      //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(constants.blobberMinBlobSize)")
                      continue
                  }

                  if blobIntensity < constants.blobberMinBlobIntensity {
                      //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of median intensity \(await blob.medianIntensity()) <= \(constants.blobberMinBlobIntensity)")
                      continue
                  }
                  
                  // only keep smaller blobs if they are bright enough
                  if !(await constants.blobberSmallBlobQualifier.allows(blob)) {
                      //Log.d("frame \(frame.frameIndex) dumping blob \(blob)")
                      continue
                  }

                  // this blob has passed these checks, keep it for now
                  ret[blob.id] = blob
              }
              return ret
          },
          .save(.filter3),
          
          .frameState(.filter4),
          // a first pass on dim isolated blob removal
          .dimIsolatedBlobRemover(.init(scanSize: 20,
                                        requiredNeighbors: 1,
                                        intensityFloor: 5000)),
          
          .save(.filter4),
          .frameState(.filter5),

          // remove isolated blobs
          .isolatedBlobRemover(.init(minNeighborSize: 4, scanSize: 24)),
          
          .save(.filter5),
          .frameState(.filter6),
          
          // remove smaller disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 60,
                                         blobsSmallerThan: 18,
                                         requiredNeighbors: 2,
                                         intensityThreshold: 15000)),
          
          // find really close linear blobs
          .linearBlobConnector(.init(scanSize: 20,
                                     blobsSmallerThan: 120,
                                     lineBorder: 10)),

          .save(.filter6),

          .frameState(.filter7),

          // remove larger disconected blobs
          .disconnectedBlobRemover(.init(scanSize: 30,
                                         blobsSmallerThan: 50,
                                         blobsLargerThan: 8,
                                         requiredNeighbors: 2)),
          .save(.filter7),
          .frameState(.filter8),
          
          .isolatedBlobRemover(.init(scanSize: 12,
                                     requiredNeighbors: 1,
                                     minBlobSize: 24)),
        
          .save(.filter8),
          .frameState(.filter9),

          // try to do more line adjustment after removing some isolated blobs
          .linearBlobConnector(.init(scanSize: 20,
                                     blobsSmallerThan: 200)),


          .save(.filter9),
          .frameState(.filter10),
          
          
          // pass on getting rid of small dim blobs
          .smallBlobRemover(.init(minBlobSize: 24,
                                  intensityFloor: 5000)),


          .save(.filter10),
          .frameState(.filter11),

          .isolatedBlobRemover(.init(scanSize: 16,
                                     requiredNeighbors: 1,
                                     minBlobSize: 50)),

          .save(.filter11),
          .frameState(.filter12),

          // try to split up blobs with more than one line in them

          // this appears to be slow
          .lineSplit(.init(minAvgDistance: 5,
                           maxLineFillAmount: 0.5,
                           minBlobsize: 500,
                           maxLines: 8000,
                           maxDistance: 12,
                           minLineScore: 12,
                           minLineCount: 10)),


          // blob line trim
          .blobLineTrim(.init(minLineLength: 65,
                              minLineFillAmount: 0.9,
                              trimAmount: 16)),


          .save(.filter12),
          .frameState(.filter13),
          
          // reconnect some lines that may have been split up
          .linearBlobConnector(.init(scanSize: 40, 
                                     blobsSmallerThan: 180,
                                     lineBorder: 2)),
          
          // pass on getting rid of small but larger, dimmer blobs
          // XXX this needs to take into account distance from others, it's killing us
          //.smallBlobRemover(.init(minBlobSize: 50,
          //intensityFloor: 7500)),
          .dimIsolatedBlobRemover(.init(scanSize: 50,
                                        requiredNeighbors: 2,
                                        minBlobSize: 50,
                                        intensityFloor: 4500)),

          .save(.filter13),
          .frameState(.filter14),


          .process() { blobs in
              var ret: [UInt16: Blob] = [:]

              for (_, blob) in blobs {
                let blobSize = await blob.size()
                  if blobSize <= constants.blobberMinBlobSize {
                      //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(constants.blobberMinBlobSize)")
                      continue
                  }

                  // this blob has passed these checks, keep it for now
                  ret[blob.id] = blob
              }
              return ret
          },

          // pass on getting rid of small but larger, dimmer blobs
          //.smallBlobRemover(.init(minBlobSize: 10)),

          .save(.filter14),
          .frameState(.filter15),


          // a final pass at isolated removal
          .isolatedBlobRemover(.init(scanSize: 50,
                                     requiredNeighbors: 1,
                                     minBlobSize: 30)),
          
          
          // split up blobs based upon user input
          .process(applyUserSlices),

          .save(.filter15),
          .frameState(.filter16),
          
          // any really big blobs with lots of small bunches that are dim can go away
          .process(removeReallyBigBlobsWithSmallDimBunches),

          // check to see if any pixel is in more than one blob
          //.blobDupeCheck("end"),

          .save(.filter16),
        ]
    }
}
