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

    override public var description: String {
        "The Excessive Blob Processor is the slowest and can dig almost any bad signal you want to remove.  Besides being slow, it also will throw up the most false positives.  Best used with the shovel tool on smaller areas of a frame."
    }
    
    override public init() {
        super.init()
        self.steps = [

          .findBlobs(.init(minPixelIntensity: 5750,
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

          .frameState(.filter2),

          // connect nearby blobs that are linear but still separate
          .linearBlobConnector(.init(scanSize: 10, 
                                     blobsSmallerThan: 6800,
                                     blobsLargerThan: 20,
                                     lineBorder: 15,
                                     minLineScore: 35,
                                     adjecentPixelsOnIteration: 5,
                                     maxBlobsProcessed: 400)),

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
          
          .frameState(.filter5),
          
          .blobLineTrim(.init(minBlobSize: 40,
                              minLineLength: 30,
                              trimAmount: 9)),

          .frameState(.filter6),

          .compactBlobIds,

          .frameState(.filter7),
           
          // split up blobs based upon user input
          .applyUserSlices,

        ]
    }
}
