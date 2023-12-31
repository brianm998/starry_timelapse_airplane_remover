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

    // pixels that are local maximums, but have a value lower than this are ignored
    let minimumLocalMaximum: UInt16

    // sorted by brightness
    public var sortedPixels: [SortablePixel] = []
    
    public convenience init(filename: String,
                            frameIndex: Int,
                            neighborType: NeighborType,
                            minimumBlobSize: Int,
                            minimumLocalMaximum: UInt16,
                            contrastMin: Double)
      async throws
    {
        if let image = try await PixelatedImage(fromFile: filename) {
            switch image.imageData {
            case .eightBit(_):
                throw "eight bit images not supported here now"
                
            case .sixteenBit(let pixelData):
                self.init(imageWidth: image.width,
                          imageHeight: image.height,
                          pixelData: pixelData,
                          frameIndex: frameIndex,
                          neighborType: neighborType,
                          minimumBlobSize: minimumBlobSize,
                          minimumLocalMaximum: minimumLocalMaximum,
                          contrastMin: contrastMin)
            }
            
            Log.v("frame \(frameIndex) loaded image of size (\(image.width), \(image.height))")
        } else {
            throw "couldn't load image from \(filename)"
        }
    }

    public init(imageWidth: Int,
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
            // too small, too dim
            if blob.size <= minimumBlobSize,
               blob.intensity < 15000 // XXX constant
            {
                return false
            }

            // allow larger blobs that are a little dimmer
            if blob.size <= minimumBlobSize * 2, // XXX constant
               blob.intensity < 10000 // XXX constant
            {
                return false
            }

            // hard cap at half the minmum size, regardless of intensity
            if blob.size <= minimumBlobSize/2 { return false } // XXX constant

            // overal blob intensity check
            if blob.intensity < minimumLocalMaximum {
                //Log.v("dumping blob of size \(blob.size) intensity \(blob.intensity)")
                return false
            }

            // this blob has passed all checks, keep it 
            return true
        }         
        Log.i("frame \(frameIndex) found \(blobs.count) blobs larger than \(minimumBlobSize) pixels")
    }
    
}


