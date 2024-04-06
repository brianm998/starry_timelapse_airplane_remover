import Foundation
import CoreGraphics
import Cocoa
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 A bright blob detector.

 Looks at an image and tries to identify separate blobs
 based upon local maximums of brightness, and changes in contrast from that.

 All pixels are sorted by brightness, and iterated over from the brightest,
 down to minimumLocalMaximum.  All nearby pixels that fall within the contrastMin threshold
 will be included in the blob.

 Directly adjcent blobs should be combined.

 All returned blobs will meet minimumBlobSize.

 Blobs dimmer on average than minimumLocalMaximum are discarded.
 */
public class FullFrameBlobber: AbstractBlobber {

    // blobs smaller than this are not returned
    public let minimumBlobSize: Int

    private let config: Config
    
    // pixels that are local maximums, but have a value lower than this are ignored
    let minimumLocalMaximum: UInt16

    // sorted by brightness
    public var sortedPixels: [SortablePixel] = []

    public init(config: Config,
                imageWidth: Int,
                imageHeight: Int,
                pixelData: [UInt16],
                frameIndex: Int,
                neighborType: NeighborType,
                minimumBlobSize: Int,
                minimumLocalMaximum: UInt16,
                contrastMin: Double)
    {
        self.minimumBlobSize = minimumBlobSize
        self.minimumLocalMaximum = minimumLocalMaximum
        self.config = config
        super.init(imageWidth: imageWidth,
                   imageHeight: imageHeight,
                   pixelData: pixelData,
                   frameIndex: frameIndex,
                   neighborType: neighborType,
                   contrastMin: contrastMin)

        Log.d("frame \(frameIndex) detecting blobs")

        for x in 0..<imageWidth {
            for y in 0..<imageHeight {
                let pixel = pixels[x][y]
                sortedPixels.append(pixel)
            }
        }

        Log.d("frame \(frameIndex) sorting pixel values")
        
        sortedPixels.sort { $0.intensity > $1.intensity }
        
        for pixel in sortedPixels {

            if pixel.status != .unknown { continue }
            
            if pixel.intensity > minimumLocalMaximum {
                
                //Log.d("examining pixel \(pixel.x) \(pixel.y) \(pixel.intensity)")
                let allNeighbors = self.neighbors(of: pixel)
                //let allNeighbors = self.allNeighbors(of: pixel, within: 4)
                let higherNeighbors = allNeighbors.filter { $0.intensity > pixel.intensity } 
                //Log.d("found \(higherNeighbors) higherNeighbors")
                if higherNeighbors.count == 0 {
                    // no higher neighbors
                    // a local maximum, this pixel is a blob seed
                    let newBlob = Blob(pixel, frameIndex: frameIndex)
                    blobs.append(newBlob)
                    
                    //Log.d("expanding from seed pixel.intensity \(pixel.intensity)")

                    // should not be necessary
                    //newBlob.add(pixel: pixel)
                    
                    expand(blob: newBlob, seedPixel: pixel)
                    
                } else {
                    // but only if it's bright enough
                    pixel.status = .background
                }                    
            } else {
                pixel.status = .background
            }
        }

        Log.d("frame \(frameIndex) initially found \(blobs.count) blobs")

        // filter out a lot of the blobs
        self.blobs = self.blobs.filter { blob in

            if let ignoreLowerPixels = config.ignoreLowerPixels,
               blob.boundingBox.min.y + ignoreLowerPixels > imageHeight
            {
                // too close to the bottom 
                return false
            }

            // these blobs are just too dim
            if blob.medianIntensity < 3800 { // XXX constant
                return false
            }

            // only keep smaller blobs if they are bright enough
            if blob.size <= 20,
               blob.medianIntensity < 5000 { return false }

            // anything this small is noise
            if blob.size <= 4 { return false }

            // this blob has passed all checks, keep it 
            return true
        }         
        Log.i("frame \(frameIndex) found \(blobs.count) blobs larger than \(minimumBlobSize) pixels")
    }
    
}


