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

public class AbstractBlobber: Blobber {

    public let imageWidth: Int
    public let imageHeight: Int
    public let pixelData: [UInt16]
    public let frameIndex: Int
    
    // [x][y] accessable array
    public var pixels: [[SortablePixel]]

    // running blob bucket
    public var blobs: [Blob] = []

    // how we search for neighbors
    public let neighborType: NeighborType

    // how close to zero (in percentage) can the intensity of pixels decrease before
    // being left out of a blob
    // zero means that only pixels of minimumLocalMaximum or higher will be in blobs
    // 50 means that all pixels half as bright or more than the maximum will be in a blob
    // 100 means that all pixels will be in a blob
    let contrastMin: Double

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
    
    public init(imageWidth: Int,
                imageHeight: Int,
                pixelData: [UInt16],
                frameIndex: Int,
                neighborType: NeighborType,
                contrastMin: Double)
    {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pixelData = pixelData
        self.frameIndex = frameIndex
        self.neighborType = neighborType
        self.contrastMin = contrastMin

        guard pixelData.count == imageWidth*imageHeight else {
            fatalError("pixelData.count \(pixelData.count) is not imageWidth*imageHeight \(imageWidth*imageHeight)")
        }
        
        Log.v("frame \(frameIndex) blobbing image of size (\(imageWidth), \(imageHeight))")

        pixels = [[SortablePixel]](repeating: [SortablePixel](repeating: SortablePixel(),
                                                              count: imageHeight),
                                   count: imageWidth)
        
        for x in 0..<imageWidth {
            for y in 0..<imageHeight {
                let pixel = SortablePixel(x: x, y: y, intensity: pixelData[y*imageWidth+x])
                pixels[x][y] = pixel
            }
        }

        // subclasses can populate blobs from the pixel array as they wish
    }    

    public var blobMap: [String: Blob] {
        var ret: [String: Blob] = [:]
        for blob in self.blobs { ret[blob.id] = blob }
        return ret
    }

    public var outputImage: PixelatedImage {

        // write out the subtractionArray here as an image
        let outputImage = PixelatedImage(width: imageWidth,
                                         height: imageHeight,
                                         imageData: PixelatedImage.DataFormat(from: outputData),
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

    public func allNeighbors(of pixel: SortablePixel, within distance: Int) -> [SortablePixel] {
        var minX = pixel.x - distance
        var minY = pixel.y - distance
        var maxX = pixel.x + distance
        var maxY = pixel.y + distance
        if minX < 0 { minX = 0 }
        if minY < 0 { minY = 0 }
        if maxX >= imageWidth { maxX = imageWidth - 1 }
        if maxY >= imageHeight { maxY = imageHeight - 1 }

        var ret: [SortablePixel] = []
        
        //Log.d("for pixel @ [\(pixel.x), \(pixel.y)] minX \(minX) minY \(minY) maxX \(maxX) maxY \(maxY)")
        
        for x in minX ... maxX {
            for y in minY ... maxY {
                if x == pixel.x && y == pixel.y
                {
                    //Log.d("cannot add pixel @ [\(x), \(y)]")
                    // central pixel is not neighbor
                } else {
                    //Log.d("adding pixel @ [\(x), \(y)]")
                    ret.append(pixels[x][y])
                }
            }
        }

        //Log.d("returning \(ret.count) pixels")
        return ret
    }

    func neighbor(_ direction: NeighborDirection, for pixel: SortablePixel) -> SortablePixel? {
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
    public var outputData: [UInt16] {
        var ret = [UInt16](repeating: 0, count: pixelData.count)

        let min:  UInt16 = 0x4FFF
        let max:  UInt16 = 0xFFFF
        let step: UInt16 = 0x1000

        var value: UInt16 = min
        
        for blob in blobs {
            //Log.v("writing out \(blob.size) pixel blob")
            for pixel in blob.pixels {
                // maybe adjust by size?
                //ret[pixel.y*imageWidth+pixel.x] = 0xFFFF / 4 + (blob.intensity/4)*3
                ret[pixel.y*imageWidth+pixel.x] = value
            }
            if value >= max { value = min }
            value += step
        }
        return ret
    }

    public func expand(blob: Blob, seedPixel firstSeed: SortablePixel) {
        //Log.d("expanding initially seed blob")

        var seedPixels: [SortablePixel] = [firstSeed]

        while let seedPixel = seedPixels.popLast() {
            // set this pixel to be part of this blob
            blob.add(pixel: seedPixel)

            // look at direct neighbors in unknown status
            for neighbor in self.neighbors(of: seedPixel) {
                if neighbor.status == .unknown {
                    // if unknown status, check contrast with initial seed pixel
                    let firstSeedContrast = firstSeed.contrast(with: neighbor)
                    if firstSeedContrast < contrastMin {
                        //Log.v("contrast \(firstSeedContrast) seedPixel.intensity neighbor.intensity \(neighbor.intensity) firstSeed.intensity \(firstSeed.intensity)")
                        seedPixels.append(neighbor)
                    } else {
                        neighbor.status = .background
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
