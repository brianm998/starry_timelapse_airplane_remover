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
 down to minIntensity.  All nearby pixels that fall within the minContrast threshold
 will be included in the blob.

 Directly adjcent blobs should be combined.

 Blobs dimmer on average than minIntensity are discarded.
 */
public class FullFrameBlobber {

    private let config: Config
    private let args: BlobFinder.Args
    
    // sorted by brightness
    public var sortedPixels: [SortablePixel] = []

    // [x][y] accessable array
    public var pixels: [[SortablePixel?]]

    public let imageWidth: Int
    public let imageHeight: Int
    public let subtractionPixelData: [UInt16]

    public let originalImage: PixelatedImage
    public let frameIndex: Int
    
    // running blob bucket
    public var blobs: [Blob] = []
    
    // how we search for neighbors
    public let neighborType: NeighborType

    public let pixelStatusTracker: PixelStatusTracker
    
    private var newBlobId: UInt16 = 1 // start at one as zero means no blob
    
    // neighbor search policies
    public enum NeighborType {
        case fourCardinal       // up and down, left and right, no corners
        case fourCorner         // diagnals only
        case eight              // the sum of the other two
    }

    // different directions from a pixel
    public enum NeighborDirection {
        case up
        case down
        case left
        case right
        case lowerRight
        case upperRight
        case lowerLeft
        case upperLeft
    }
    
    public init(config: Config,
                args: BlobFinder.Args,
                imageWidth: Int,
                imageHeight: Int,
                subtractionPixelData: [UInt16],
                originalImage: PixelatedImage,
                frameIndex: Int,
                neighborType: NeighborType) async
    {
        // pixels that are local maximums, but have a value lower than this are ignored
        let minIntensity = args.minPixelIntensity
        self.pixelStatusTracker = PixelStatusTracker(frameIndex: frameIndex,
                                                     imageWidth: imageWidth,
                                                     imageHeight: imageHeight)
        self.config = config
        self.args = args
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.subtractionPixelData = subtractionPixelData
        self.originalImage = originalImage
        self.frameIndex = frameIndex
        self.neighborType = neighborType

        guard subtractionPixelData.count == imageWidth*imageHeight else {
            fatalError("subtractionPixelData.count \(subtractionPixelData.count) is not imageWidth*imageHeight \(imageWidth*imageHeight)")
        }
        
        Log.v("frame \(frameIndex) blobbing image of size (\(imageWidth), \(imageHeight))")

        pixels = [[SortablePixel?]](repeating: [SortablePixel?](repeating: nil,
                                                                count: imageHeight),
                                    count: imageWidth)


        var maxY = imageHeight
        
        if let ignoreLowerPixels = config.ignoreLowerPixels {
            maxY = imageHeight - ignoreLowerPixels
            if maxY < 0 { maxY = 0 }
        }

        let minContrast = args.minContrast
        
        for x in 0..<imageWidth {
            for y in 0..<maxY {
                let intensity = subtractionPixelData[y*imageWidth+x]

                if intensity > minIntensity {
                    // these pixels are both sorted and added to the pixels multi array
                    let pixel = SortablePixel(x: x, y: y, intensity: intensity)
                    pixels[x][y] = pixel
                    sortedPixels.append(pixel)
                } else {
                    // these pixels are dimmer, and might get added to the pixels multi array
                    let diff = Double(abs(Int32(intensity) - Int32(minIntensity)))
                    let max = Double(max(intensity, minIntensity))
                
                    let contrast = diff / max * 100

                    // some pixels are too dim to even track
                    if contrast < minContrast {
                        let pixel = SortablePixel(x: x, y: y, intensity: intensity)
                        pixels[x][y] = pixel
                    }
                }
            }
        }
    }

    public func sortPixels() {
        Log.d("frame \(frameIndex) sorting pixel values")
        sortedPixels.sort { $0.intensity > $1.intensity }
    }
    
    public func process() async {
        Log.d("frame \(frameIndex) detecting blobs")

        for pixel in sortedPixels {

            if await pixelStatusTracker.status(of: pixel) != .unknown { continue }

            //Log.d("examining pixel \(pixel.x) \(pixel.y) \(pixel.intensity)")
            let allNeighbors = self.neighbors(of: pixel)
            //let allNeighbors = self.allNeighbors(of: pixel, within: 4)
            let higherNeighbors = allNeighbors.filter { $0.intensity > pixel.intensity } 
            //Log.d("found \(higherNeighbors) higherNeighbors")
            if higherNeighbors.count == 0 {
                // no higher neighbors
                // a local maximum, this pixel is a blob seed

                if newBlobId < UInt16.max {
                    let newBlob = Blob(pixel,
                                       id: newBlobId,
                                       frameIndex: frameIndex,
                                       statusTracker: pixelStatusTracker)


                    await expand(blob: newBlob, seedPixel: pixel)
                    //Log.d("frame \(frameIndex) creating blob \(newBlob)")
                    
                    /*

                     after we expand, and before we append, try a further test:

                     try starting a new blob on the original image, and compare the result
                     to what we got here.

                     if the blob from the original image is a lot bigger, and brighter, then discard
                     
                     only keep if the number of bright pixels isn't all that much larger (how much?)
                     
                     */

                    // examine the blob in the original image.

                    // XXX maybe make this a classification criteria instead
                    // of just dumping them outright here?
                    /*
                     XXX this is blowing away some blobs that we want, even bright ones.
                     it does get rid of lots of horizon blobs however.

                     need to expose this as a classification feature

                     but it requires the original image, so

                     use imageCache inside of Outlier group to allow
                     calculating this value

                     */

                    let borderBrightness = await originalImage.borderBrightness(of: newBlob.pixels)

//                    Log.d("frame \(frameIndex) blob \(newBlob) has borderBrightness \(borderBrightness)") 

                    // XXX delay this check until later in the process
                    // XXX make original image avilalbe to blob for this
                    
                    if borderBrightness < 0.5 { // XXX guess
                        newBlobId += 1
                        blobs.append(newBlob)
                    }
                    //Log.d("expanding from seed pixel.intensity \(pixel.intensity)")

                } else {
                    // we've got more than UInt16.max blob seeds, that's a lot
                    // don't create more blobs
                    Log.w("frame \(frameIndex) reached newBlobId \(newBlobId), cannot create new blobs") 
                    break
                }

                
            } else {
                // but only if it's bright enough
                await pixelStatusTracker.record(status: .background, for: pixel)
            }                    
        }

        Log.i("frame \(frameIndex) found \(blobs.count) blobs")
    }
    
    public var blobMap: BlobMap {
        var ret: BlobMap = [:]
        for blob in self.blobs { ret[blob.id] = blob }
        return ret
    }

    public func outputImage() async -> PixelatedImage {

        // write out the subtractionArray here as an image
        let outputImage = PixelatedImage(width: imageWidth,
                                         height: imageHeight,
                                         imageData: PixelatedImage.DataFormat(from: await self.outputData()),
                                         bitsPerPixel: 16,
                                         bytesPerRow: 2*imageWidth,
                                         bitsPerComponent: 16,
                                         bytesPerPixel: 2,
                                         bitmapInfo: .byteOrder16Little, 
                                         componentsPerPixel: 1,
                                         colorSpace: CGColorSpaceCreateDeviceGray(),
                                         ciFormat: .L16)

        return outputImage
    }

    // for the NeighborType of this Blobber
    public func neighbors(of pixel: SortablePixel) -> [SortablePixel] {
        return neighborsInt(pixel, self.neighborType)
    }

    fileprivate func neighbor(_ direction: NeighborDirection, for pixel: SortablePixel) -> SortablePixel? {
        if pixel.x == 0,
           (direction == .left || 
            direction == .lowerLeft ||
            direction == .upperLeft)
        {
            return nil
        }
        if pixel.y == 0,
           (direction == .up ||
            direction == .upperRight ||
            direction == .upperLeft)
        {
            return nil
        }
        if pixel.x == 0,
           (direction == .left ||
            direction == .lowerLeft ||
            direction == .upperLeft)
        {
            return nil
        }
        if pixel.y == imageHeight - 1,
           (direction == .down ||
            direction == .lowerLeft ||
            direction == .lowerRight)
        {
            return nil
        }
        if pixel.x == imageWidth - 1,
           (direction == .right ||
            direction == .lowerRight ||
            direction == .upperRight)
        {
            return nil
        }
        switch direction {
        case .up:
            return pixels[pixel.x][pixel.y-1]
        case .down:
            return pixels[pixel.x][pixel.y+1]
        case .left:
            return pixels[pixel.x-1][pixel.y]
        case .right:
            return pixels[pixel.x+1][pixel.y]
        case .lowerRight:
            return pixels[pixel.x+1][pixel.y+1]
        case .upperRight:
            return pixels[pixel.x+1][pixel.y-1]
        case .lowerLeft:
            return pixels[pixel.x-1][pixel.y+1]
        case .upperLeft:
            return pixels[pixel.x-1][pixel.y-1]
        }
    }

    // used for writing out blob data for viewing 
    public func outputData() async -> [UInt16] {
        var ret = [UInt16](repeating: 0, count: subtractionPixelData.count)

        let min:  UInt16 = 0x4FFF
        let max:  UInt16 = 0xFFFF
        let step: UInt16 = 0x1000

        var value: UInt16 = min
        
        for blob in blobs {
            //Log.v("writing out \(blob.size) pixel blob")
            for pixel in await blob.getPixels() {
                // maybe adjust by size?
                //ret[pixel.y*imageWidth+pixel.x] = 0xFFFF / 4 + (blob.intensity/4)*3
                ret[pixel.y*imageWidth+pixel.x] = value
            }
            if value >= max { value = min }
            value += step
        }
        return ret
    }

    public func expand(blob: Blob, seedPixel firstSeed: SortablePixel) async {
        //Log.d("expanding initially seed blob")

        var seedPixels: [SortablePixel] = [firstSeed]
        let minContrast = args.minContrast
        
        while let seedPixel = seedPixels.popLast() {
            // set this pixel to be part of this blob
            await blob.add(pixel: seedPixel)

            // look at direct neighbors in unknown status
            for neighbor in self.neighbors(of: seedPixel) {

                if await pixelStatusTracker.status(of: neighbor) == .unknown {
                    // if unknown status, check contrast with initial seed pixel
                    let firstSeedContrast = firstSeed.contrast(with: neighbor)
                    if firstSeedContrast < minContrast {
                        //Log.v("contrast \(firstSeedContrast) seedPixel.intensity neighbor.intensity \(neighbor.intensity) firstSeed.intensity \(firstSeed.intensity)")
                        seedPixels.append(neighbor)
                    } else {
                        await pixelStatusTracker.record(status: .background, for: neighbor)
                    }
                }
            }
        }

        //Log.d("after expansion, blob has \(blob.size) pixels")
    }
    
    // for any NeighborType
    fileprivate func neighborsInt(_ pixel: SortablePixel,
                                  _ type: NeighborType) -> [SortablePixel]
    {
        var ret: [SortablePixel] = []
        switch type {
            // up and down, left and right, no corners
        case .fourCardinal:
            if let left = neighbor(.left, for: pixel) {
                ret.append(left)
            }
            if let right = neighbor(.right, for: pixel) {
                ret.append(right)
            }
            if let up = neighbor(.up, for: pixel) {
                ret.append(up)
            }
            if let down = neighbor(.down, for: pixel) {
                ret.append(down)
            }
            
            // diagnals only
        case .fourCorner:
            if let upperLeft = neighbor(.upperLeft, for: pixel) {
                ret.append(upperLeft)
            }
            if let upperRight = neighbor(.upperRight, for: pixel) {
                ret.append(upperRight)
            }
            if let lowerLeft = neighbor(.lowerLeft, for: pixel) {
                ret.append(lowerLeft)
            }
            if let lowerRight = neighbor(.lowerRight, for: pixel) {
                ret.append(lowerRight)
            }

            // the sum of the other two
        case .eight:        
            return neighborsInt(pixel, .fourCardinal) + 
                   neighborsInt(pixel, .fourCorner)
            
        }
        return ret

    }
}


