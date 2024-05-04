import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


// analyze the blobs with kernel hough transform data from the subtraction image
// filters the blob map, and combines nearby blobs on the same line
class BlobKHTAnalysis: AbstractBlobAnalyzer {

    private let maxVotes = 12000     // lines with votes over this are max color on kht image
    private let khtImageBase = 0x1F  // dimmest lines will be 

    let houghLines: [MatrixElementLine]

    let imageAccessor: ImageAccess
    let config: Config
    
    init(houghLines: [MatrixElementLine],
         blobMap: [String: Blob],
         config: Config,
         width: Int,
         height: Int,
         frameIndex: Int,
         imageAccessor: ImageAccess) 
    {
        self.houghLines = houghLines
        self.imageAccessor = imageAccessor
        self.config = config
        super.init(blobMap: blobMap,
                   width: width,
                   height: height,
                   frameIndex: frameIndex)
    }

    public func process() async throws {
        var khtImage: [UInt8] = []
        if config.writeOutlierGroupFiles {
            khtImage = [UInt8](repeating: 0, count: width*height)
        }

        Log.i("frame \(frameIndex) loaded subtraction image")

        for elementLine in houghLines {
            
            let element = elementLine.element

            // when theta is around 300 or more, then we get a bad line here :(
            let line = elementLine.originZeroLine
            
            if line.votes < constants.khtMinLineVotes { continue }

            //Log.i("frame \(frameIndex) matrix element [\(element.x), \(element.y)] -> [\(element.width), \(element.height)] processing line theta \(line.theta) rho \(line.rho) votes \(line.votes) blobsToProcess \(blobsToProcess.count)")

            var brightnessValue: UInt8 = 0xFF

            // calculate brightness to display line on kht image
            if line.votes < maxVotes {
                brightnessValue = UInt8(Double(line.votes)/Double(maxVotes) *
                                          Double(0xFF - khtImageBase) +
                                          Double(khtImageBase))
            }

            var lastBlob = LastBlob()
            
            let extra = constants.khtLineExtensionAmount
            line.iterate(on: elementLine, withExtension: extra) { x, y, direction in
                if x < width,
                   y < height
                {
                    if config.writeOutlierGroupFiles {
                        // write kht image data
                        let index = y*width+x
                        if khtImage[index] < brightnessValue {
                            khtImage[index] = brightnessValue
                        }
                    }

                    // do blob processing at this location
                    processBlobsAt(x: x,
                                   y: y,
                                   on: line,
                                   iterationOrientation: direction,
                                   lastBlob: &lastBlob)
                    
                }
            }
        }

        if config.writeOutlierGroupFiles {
            // save image of kht lines
            let image = PixelatedImage(width: width, height: height,
                                       grayscale8BitImageData: khtImage)
            try await imageAccessor.save(image, as: .houghLines,
                                         atSize: .original, overwrite: true)
            try await imageAccessor.save(image, as: .houghLines,
                                         atSize: .preview, overwrite: true)
        }
    }
}
