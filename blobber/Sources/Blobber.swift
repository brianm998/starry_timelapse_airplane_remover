import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore
import ShellOut

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

@main
struct BlobberCli: AsyncParsableCommand {

    @Option(name: [.short, .customLong("input-file")], help:"""
        Input file to blob
        """)
    var inputFile: String?
    
    @Option(name: [.short, .customLong("output-file")], help:"""
        Output file to write blobbed tiff image to
        """)
    var outputFile: String
    
    mutating func run() async throws {

        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)
        
        Log.v("TEST")
        let cloud_base = "/sp/tmp/LRT_05_20_2023-a9-4-aurora-topaz-star-aligned-subtracted"
        let lots_of_clouds = [
          "232": "\(cloud_base)/LRT_00234-severe-noise.tiff",
          "574": "\(cloud_base)/LRT_00575-severe-noise.tiff",
          "140": "\(cloud_base)/LRT_00141-severe-noise.tiff",
          "160": "\(cloud_base)/LRT_00161-severe-noise.tiff",
          "184": "\(cloud_base)/LRT_00185-severe-noise.tiff",
          "192": "\(cloud_base)/LRT_00193-severe-noise.tiff",
          "236": "\(cloud_base)/LRT_00237-severe-noise.tiff",
          "567": "\(cloud_base)/LRT_00568-severe-noise.tiff",
          "783": "\(cloud_base)/LRT_00784-severe-noise.tiff",
          "1155": "\(cloud_base)/LRT_001156-severe-noise.tiff"
        ]

        let no_cloud_base = "/sp/tmp/LRT_07_15_2023-a7iv-4-aurora-topaz-star-aligned-subtracted"
        let no_clouds = [
          "800": "\(no_cloud_base)/LRT_00801-severe-noise.tiff",
          "654": "\(no_cloud_base)/LRT_00655-severe-noise.tiff",
          "689": "\(no_cloud_base)/LRT_00690-severe-noise.tiff",
          "882": "\(no_cloud_base)/LRT_00883-severe-noise.tiff",
          "349": "\(no_cloud_base)/LRT_00350-severe-noise.tiff",
          "241": "\(no_cloud_base)/LRT_00242-severe-noise.tiff"
        ]


        let small_image = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT_00350-severe-noise_crop.tiff"

        let blobber = try await Blobber(filename: small_image)

        try blobber.outputImage.writeTIFFEncoding(toFilename: outputFile)
    }
}

class Blobber {
    let image: PixelatedImage
    let pixelData: [UInt16]

    // [x][y] accessable array
    var pixels: [[SortablePixel]]

    // sorted by brightness
    var sortedPixels: [SortablePixel] = []
    var blobs: [Blob] = []
    var outputData: [UInt16]

    let neighborType: NeighborType
    let lowIntensityLimit: UInt16 = 800
    let blobMinimumSize = 20
    
    enum NeighborType {
        case fourCardinal       // up and down, left and right, no corners
        case fourCorner         // diagnals only
        case eight              // the sum of the other two
    }

    enum NeighborDirection {
        case up
        case down
        case left
        case right
        case lowerRight
        case upperRight
        case lowerLeft
        case upperLeft
    }
    
    init(filename: String,
         neighborType: NeighborType = .eight) async throws
    {
        (self.image, self.pixelData) = try await PixelatedImage.loadUInt16Array(from: filename)
        self.neighborType = neighborType

        Log.v("loaded image of size (\(image.width), \(image.height))")

        Log.v("blobbing image of size (\(image.width), \(image.height))")

        Log.d("loading pixels")

        pixels = [[SortablePixel]](repeating: [SortablePixel](repeating: SortablePixel(),
                                                              count: image.height),
                                   count: image.width)
        
        for x in 0..<image.width {
            for y in 0..<image.height {
                let pixel = SortablePixel(x: x, y: y, intensity: pixelData[y*image.width+x])
                sortedPixels.append(pixel)
                pixels[x][y] = pixel
            }
        }

        Log.d("sorting pixel values")

        sortedPixels.sort { $0.intensity > $1.intensity }

        self.outputData = [UInt16](repeating: 0, count: pixelData.count)

        Log.d("detecting blobs")
        
        for pixel in sortedPixels {
            //Log.d("examining pixel \(pixel.x) \(pixel.y) \(pixel.intensity)")
            let higherNeighbors = self.higherNeighbors(pixel)
            //Log.d("found \(higherNeighbors) higherNeighbors")
            if higherNeighbors.count == 0 {
                // no higher neighbors
                // a local maximum, this pixel is a blob seed
                if pixel.intensity > lowIntensityLimit {
                    let newBlob = Blob(pixel)
                    newBlob.pixels.append(pixel)
                    pixel.status = .blobbed(newBlob)
                    blobs.append(newBlob)
                } else {
                    // but only if it's bright enough
                    pixel.status = .background
                }                    
            } else {
                // see if any higher neighbors are already backgrounded
                var hasHigherBackgroundNeighbor = false
                for neighbor in higherNeighbors {
                    switch neighbor.status {
                    case .background:
                        hasHigherBackgroundNeighbor = true
                    default:
                        break
                    }
                }
                if hasHigherBackgroundNeighbor {
                    // if has at least one higher neighbor, which is background,
                    // then it must be background
                    pixel.status = .background
                } else {
                    // see how many blobs neighbors are already part of
                    var nearbyBlobs: [String:Blob] = [:]
                    for neighbor in higherNeighbors {
                        switch neighbor.status {
                        case .blobbed(let nearbyBlob):
                            nearbyBlobs[nearbyBlob.id] = nearbyBlob
                        default:
                            break
                        }
                    }

                    if nearbyBlobs.count > 1 {
                        // more than one higher neighbor is part of a blob
                        // and they are in different blobs 
                        // this pixel must be background
                        pixel.status = .background

                        // stopy any groups of higher neighbors from growing further

                        for neighbor in higherNeighbors {
                            switch neighbor.status {
                            case .blobbed(let nearbyBlob):
                                nearbyBlob.canGrow = false
                            default:
                                break
                            }
                        }
                        
                    } else {
                        // this pixel has one or more higher neighbors, which are all
                        // parts of the same blob.
                        if let blob = nearbyBlobs.first?.value,
                           blob.canGrow
                        {
                            // add this pixel to the blob
                            pixel.status = .blobbed(blob)
                            blob.pixels.append(pixel)
                        } else {
                            // this pixel is background
                            pixel.status = .background
                        }
                    }
                }
            }
        }

        Log.d("initially found \(blobs.count) blobs")

        self.blobs = self.blobs.filter { $0.pixels.count >= blobMinimumSize }         

        Log.d("found \(blobs.count) blobs larger than \(blobMinimumSize) pixels")

        for blob in blobs {
            for pixel in blob.pixels {
                // maybe adjust by size?
                outputData[pixel.y*image.width+pixel.x] = blob.intensity
            }
        }
    }

    var outputImage: PixelatedImage {
        let imageData = outputData.withUnsafeBufferPointer { Data(buffer: $0)  }
        
        // write out the subtractionArray here as an image
        let outputImage = PixelatedImage(width: image.width,
                                         height: image.height,
                                         rawImageData: imageData,
                                         bitsPerPixel: 16,
                                         bytesPerRow: 2*image.width,
                                         bitsPerComponent: 16,
                                         bytesPerPixel: 2,
                                         bitmapInfo: .byteOrder16Little, 
                                         pixelOffset: 0,
                                         colorSpace: CGColorSpaceCreateDeviceGray(),
                                         ciFormat: .L16)

        return outputImage
    }

    // for the NeighborType of this Blobber
    func higherNeighbors(_ pixel: SortablePixel) -> [SortablePixel] {
        return higherNeighborsInt(pixel, neighborType)
    }

    // for any NeighborType
    fileprivate func higherNeighborsInt(_ pixel: SortablePixel,
                                        _ type: NeighborType) -> [SortablePixel]
    {
        var ret: [SortablePixel] = []
        switch type {

            // up and down, left and right, no corners
        case .fourCardinal:
            if let left = neighbor(.left, for: pixel),
               left.intensity > pixel.intensity
            {
                ret.append(left)
            }
            if let right = neighbor(.right, for: pixel),
               right.intensity > pixel.intensity
            {
                ret.append(right)
            }
            if let up = neighbor(.up, for: pixel),
               up.intensity > pixel.intensity
            {
                ret.append(up)
            }
            if let down = neighbor(.down, for: pixel),
               down.intensity > pixel.intensity
            {
                ret.append(down)
            }
            
            // diagnals only
        case .fourCorner:
            if let upperLeft = neighbor(.upperLeft, for: pixel),
               upperLeft.intensity > pixel.intensity
            {
                ret.append(upperLeft)
            }
            if let upperRight = neighbor(.upperRight, for: pixel),
               upperRight.intensity > pixel.intensity
            {
                ret.append(upperRight)
            }
            if let lowerLeft = neighbor(.lowerLeft, for: pixel),
               lowerLeft.intensity > pixel.intensity
            {
                ret.append(lowerLeft)
            }
            if let lowerRight = neighbor(.lowerRight, for: pixel),
               lowerRight.intensity > pixel.intensity
            {
                ret.append(lowerRight)
            }

            // the sum of the other two
        case .eight:        
            return higherNeighborsInt(pixel, .fourCardinal) + 
                   higherNeighborsInt(pixel, .fourCorner)
            
        }
        return ret
    }

    func neighbor(_ direction: NeighborDirection, for pixel: SortablePixel) -> SortablePixel? {
        if pixel.x == 0 {
            if direction == .left || 
               direction == .lowerLeft ||
               direction == .upperLeft
            {
                return nil
            }
        }
        if pixel.y == 0 {
            if direction == .up ||
               direction == .upperRight ||
               direction == .upperLeft
            {
                return nil
            }
        }
        if pixel.x == 0 {
            if direction == .left ||
               direction == .lowerLeft ||
               direction == .upperLeft
            {
                return nil
            }
        }
        if pixel.y == image.height - 1 {
            if direction == .down ||
               direction == .lowerLeft ||
               direction == .lowerRight
            {
                return nil
            }
        }
        if pixel.x == image.width - 1 {
            if direction == .right ||
               direction == .lowerRight ||
               direction == .upperRight
            {
                return nil
            }
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
}

class Blob {
    let id: String
    var pixels: [SortablePixel]
    var canGrow: Bool = true

    var intensity: UInt16 {
        var max: UInt32 = 0
        for pixel in pixels {
            max += UInt32(pixel.intensity)
        }
        max /= UInt32(pixels.count)
        return UInt16(max)
    }
    
    init(_ pixel: SortablePixel) {
        self.pixels = [pixel]
        self.id = "\(pixel.x) x \(pixel.y)"
    }
}

class SortablePixel {
    let x: Int
    let y: Int
    let intensity: UInt16
    var status = Status.unknown
    
    enum Status {
        case unknown
        case background
        case blobbed(Blob)
    }
    
    init(x: Int = 0,
         y: Int = 0,
         intensity: UInt16 = 0)
    {
        self.x = x
        self.y = y
        self.intensity = intensity
    }
}

fileprivate let fileManager = FileManager.default
