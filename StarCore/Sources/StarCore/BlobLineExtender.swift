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

// looks for lines in blobs and tries to extend them to cover them fully
class BlobLineExtender: AbstractBlobAnalyzer {

    /*
        above threshold: 26.2/3.19 = 8.21316614420062695924  // this blob was a real line
        below threshold: 38.6/6.82 = 5.65982404692082111436  // this blob was not a real line
     */
    // threshold of line length / average distance
    // true lines have a higher value
    private let threshold: Double = 6.5 // XXX guess from the two above

    private let pixelData: [UInt16]
    
    init(pixelData: [UInt16],
         blobMap: [String: Blob],
         config: Config,
         width: Int,
         height: Int,
         frameIndex: Int,
         imageAccessor: ImageAccess)
    {
        self.pixelData = pixelData
        
        super.init(blobMap: blobMap,
                   config: config,
                   width: width,
                   height: height,
                   frameIndex: frameIndex,
                   imageAccessor: imageAccessor)

        for (index, blob) in blobMap.values.enumerated() {

            if blob.size < 45 { continue } // XXX constant
            
            // if no line, pass
            if let line = blob.originZeroLine,
               let centralCoord = blob.centralLineCoord
            {
                // calculate average distance from line and line length for each blob with a line
                
                let (avgDist, lineLength) = blob.averageDistanceAndLineLength(from: line)

                let score = lineLength/avgDist

                if score > threshold {
                    //iterate on line and try to extend this blob with more pixels

                    // compare pixels on iteration to this intensity
                    let initialIntensity = blob.intensity

                    // threshold for how much dimmer a pixel can be
                    // than the average intensity of the blob
                    // lowering it gives more noise
                    // raising it shrinks wanted groups
                    let minIntensity = UInt16(Double(initialIntensity)*0.72) // XXX constant

                    //var referenceCoord = centralCoord
                    
                    line.iterate(.forwards, from: centralCoord) { x, y, direction in
                        if x >= 0,
                           y >= 0,
                           x < width,
                           y < height
                        {
                            if processAt(x: x,
                                         y: y,
                                         blob: blob,
                                         minIntensity: minIntensity)
                            {
                                // update reference coord
                                //referenceCoord = DoubleCoord(x: Double(x), y: Double(y))
                                
                                // we need to re-calculate the line and re-iterate from here
                            }
                        }
                        return shouldContinue(from: centralCoord,//referenceCoord,
                                              x: x, y: y,
                                              max: 140) // XXX constant
                    }

                    //referenceCoord = centralCoord
                    
                    line.iterate(.backwards, from: centralCoord) { x, y, direction in
                        if x >= 0,
                           y >= 0,
                           x < width,
                           y < height
                        {
                            if processAt(x: x,
                                         y: y,
                                         blob: blob,
                                         minIntensity: minIntensity)
                            {
                                // update reference coord
                                //referenceCoord = DoubleCoord(x: Double(x), y: Double(y))

                                // we need to re-calculate the line and re-iterate from here
                            } 
                        }
                        return shouldContinue(from: centralCoord,//referenceCoord,
                                              x: x, y: y,
                                              max: 140) // XXX constant
                    }
                }
            }
        }
    }

    private func processAt(x sourceX: Int,
                           y sourceY: Int,
                           blob: Blob,
                           minIntensity: UInt16) -> Bool
    {

        // how far away from x,y do we look for a brigher pixel?
        let searchArea = 3

        var newPixels: [SortablePixel] = []
        
        for x in sourceX-searchArea..<sourceX+searchArea*2+1 {
            for y in sourceY-searchArea..<sourceY+searchArea*2+1 {
                if x >= 0,
                   y >= 0,
                   x < width,
                   y < height
                {
                    let index = y*width+x

                    // already a blob at this pixel
                    if let blobId = blobRefs[index] {
                        continue //return blobId == blob.id
                    } 

                    let pixelIntensity = pixelData[index]

                    if pixelIntensity > minIntensity {
                        newPixels.append(SortablePixel(x: x, y: y, intensity: pixelIntensity))
                    }
                }
            }
        }

        if newPixels.count > 0 {
            for pixel in newPixels {
                if blob.distanceTo(x: pixel.x, y: pixel.y) < 20 { // XXX constant
                    // append this pixel to the blob as it's close enough to it
                    blob.add(pixel: pixel)
                    
                    // set the blobsRefs for it
                    blobRefs[pixel.y*width+pixel.x] = blob.id
                }
            }
            return true
        }
        return false
    }
    
    private func shouldContinue(from origin: DoubleCoord,
                                x: Int, y: Int, max: Double) -> Bool
    {
        let x_diff = origin.x - Double(x)
        let y_diff = origin.y - Double(y)
        return sqrt(x_diff*x_diff + y_diff*y_diff) < max
    }
}
