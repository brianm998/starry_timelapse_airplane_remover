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


        let clouds_cropped = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT00161_cropped.tif"
        let clouds_cropped_3x_blur = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT00161_cropped_3x_blur.tif"
        let clouds_cropped_2x_blur = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT00161_cropped_2x_blur.tif"
        let clouds_cropped_1x_blur = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT00161_cropped_1x_blur.tif"
        

        
        let small_image = "/Users/brian/git/nighttime_timelapse_airplane_remover/test/LRT_00350-severe-noise_crop.tiff"

        let blobber = try await Blobber(filename:
                                          lots_of_clouds["160"]!,
//                                          clouds_cropped_1x_blur,
//                                          clouds_cropped,
//                                          small_image,
                                        neighborType: .fourCardinal)

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

    let neighborType: NeighborType

    // no blurring
    //let lowIntensityLimit: UInt16 = 2500 // looks good, but noisy still
    //let lowIntensityLimit: UInt16 = 6500 // nearly F-ing nailed it
    //let lowIntensityLimit: UInt16 = 7000 // a nice spot for unblurred
    //let lowIntensityLimit: UInt16 = 7200 // pretty good
    //let lowIntensityLimit: UInt16 = 8500 // still some noise, but airplane streaks too small

    // 3x gaussian blur
    //let lowIntensityLimit: UInt16 = 3000 // caught the planes, and lots of noise, took forever
    //let lowIntensityLimit: UInt16 = 5000 // got about half of each plane track, still noise
    //let lowIntensityLimit: UInt16 = 7000 // completely missed the plane tracks, and most else too

    // 2x gaussian blur
    //let lowIntensityLimit: UInt16 = 5000   // not bad, still some noise and missing some tracks
    
    // 1x gaussian blur
    //let lowIntensityLimit: UInt16 = 5000   // 
    
    // new trials
    //let lowIntensityLimit: UInt16 = 4000   // airplane the same, more noise
    //let lowIntensityLimit: UInt16 = 5000   // mostly works, skipps some spots, some noise
    //let lowIntensityLimit: UInt16 = 7000   // airplanes the same, less noise
    let lowIntensityLimit: UInt16 = 7777 
    //let lowIntensityLimit: UInt16 = 8500   // less noise, but lost a little bit of airplane
    
    let blobMinimumSize = 30

//        let contrastMin: Double = 8000 // XXX hardly shows anything 
//        let contrastMin: Double = 18000 // shows airplane streaks about half
//        let contrastMin: Double = 28000 // got almost all of the airplanes, some noise too
//        let contrastMin: Double = 30000 // got almost all of the airplanes, some noise too
//        let contrastMin: Double = 35000 // looks better
    let contrastMin: Double = 38000 // looks better
//        let contrastMin: Double = 40000 // pretty much got the airplanes, but 8 minutes to paint :(
    
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
    
    convenience init(filename: String,
                     neighborType: NeighborType = .eight) async throws
    {
        let (image, pixelData) =
          try await PixelatedImage.loadUInt16Array(from: filename)

        try await self.init(image: image,
                            pixelData: pixelData,
                            neighborType: neighborType)
    }

    init(image: PixelatedImage,
         pixelData: [UInt16],
         neighborType: NeighborType = .eight) async throws
    {
        self.image = image
        self.pixelData = pixelData
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

        Log.d("detecting blobs")
        
        for pixel in sortedPixels {

            if pixel.status != .unknown { continue }
            
            //Log.d("examining pixel \(pixel.x) \(pixel.y) \(pixel.intensity)")
            let higherNeighbors = self.higherNeighbors(pixel)
            //Log.d("found \(higherNeighbors) higherNeighbors")
            if higherNeighbors.count == 0 {
                // no higher neighbors
                // a local maximum, this pixel is a blob seed
                if pixel.intensity > lowIntensityLimit {
                    let newBlob = Blob(pixel)
                    blobs.append(newBlob)

                    Log.d("expanding from seed pixel.intensity \(pixel.intensity)")
                    
                    expand(blob: newBlob, seedPixel: pixel)
                    
                } else {
                    // but only if it's bright enough
                    pixel.status = .background
                }                    
            } else {
                // see if any higher neighbors are already backgrounded
                var hasHigherBackgroundNeighbor = false
                for neighbor in higherNeighbors {
                    hasHigherBackgroundNeighbor = (neighbor.status == .background)
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

                    if let (id, firstBlob) = nearbyBlobs.randomElement() {
                        nearbyBlobs.removeValue(forKey: id)
                        Log.d("nearbyBlobs.count \(nearbyBlobs.count)")
                        
                        if nearbyBlobs.count > 0 {
                            Log.i("concensing \(nearbyBlobs.count) blobs into blob with \(firstBlob.pixels.count) pixels")
                            // we have extra blobs, absorb them 
                            for otherBlob in nearbyBlobs.values {
                                firstBlob.absorb(otherBlob)
                                
                                // remove otherBlob from blobs
                                self.blobs = self.blobs.filter() { $0.id != otherBlob.id }
                            }
                            Log.d("first blob now has \(firstBlob.pixels.count) pixels")
                        }
                        
                        // add this pixel to the blob
                        pixel.status = .blobbed(firstBlob)
                        firstBlob.pixels.append(pixel)
                    }
                }
            }
        }
        
        Log.d("initially found \(blobs.count) blobs")
        
        self.blobs = self.blobs.filter { $0.pixels.count >= blobMinimumSize }         

        Log.d("found \(blobs.count) blobs larger than \(blobMinimumSize) pixels")
    }

    var outputData: [UInt16] {
        var ret = [UInt16](repeating: 0, count: pixelData.count)
        
        for blob in blobs {
            Log.v("writing out \(blob.pixels.count) pixel blob")
            for pixel in blob.pixels {
                // maybe adjust by size?
                ret[pixel.y*image.width+pixel.x] = 0xFFFF / 4 + (blob.intensity/4)*3
            }
        }
        return ret
    }

    func expand(blob: Blob, seedPixel firstSeed: SortablePixel) {
        Log.d("expanding initially seed blob")
        
        var seedPixels: [SortablePixel] = [firstSeed]
        
        while let seedPixel = seedPixels.popLast() {
            // first set this pixel to be part of this blob
            seedPixel.status = .blobbed(blob)
            blob.pixels.append(seedPixel)

            // next examine neighboring pixels
            let neighbors = neighbors(seedPixel)
            for neighbor in neighbors {
                switch neighbor.status {
                case .unknown:
                    let contrast = seedPixel.contrast(with: neighbor,
                                                      maxBright: firstSeed.intensity)
                    let firstSeedContrast = firstSeed.contrast(with: neighbor,
                                                               maxBright: firstSeed.intensity)
                    if contrast < contrastMin,
                       firstSeedContrast < contrastMin
                    {
                        //Log.v("contrast \(contrast) seedPixel.intensity \(seedPixel.intensity) neighbor.intensity \(neighbor.intensity) firstSeed.intensity \(firstSeed.intensity)")
                        seedPixels.append(neighbor)
                    } else {
                        neighbor.status = .background
                    }

                case .blobbed(let otherBlob):
                    if otherBlob.id != blob.id {
                        blob.absorb(otherBlob)
                        self.blobs = self.blobs.filter() { $0.id != otherBlob.id }
                    }
                    
                case.background:
                    break
                } 
            }
        }

        Log.d("after expansion, blob has \(blob.pixels.count) pixels")
    }
    
    var outputImage: PixelatedImage {
        let imageData = outputData.withUnsafeBufferPointer { Data(buffer: $0) }
        
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

    // for the NeighborType of this Blobber
    func neighbors(_ pixel: SortablePixel) -> [SortablePixel] {
        return neighborsInt(pixel, neighborType)
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


