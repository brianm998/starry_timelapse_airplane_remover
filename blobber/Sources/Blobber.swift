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

        //let (image, pixelData) = try await PixelatedImage.loadUInt16Array(from: no_clouds[inputFile]!)
        let blobber = try await Blobber(filename: small_image)

        // XXX do something ?
    }
}

class Blobber {
    let image: PixelatedImage
    let pixelData: [UInt16]
    
    init(filename: String) async throws {
        (image, pixelData) = try await PixelatedImage.loadUInt16Array(from: filename)

        Log.v("loaded image of size (\(image.width), \(image.height))")

        Log.v("blobbing image of size (\(image.width), \(image.height))")

        var sortedPixels: [SortablePixel] = []

        Log.d("loading pixels")

        var pixels = [[SortablePixel]](repeating: [SortablePixel](repeating: SortablePixel(),
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

        var blobs: [Blob] = []

        let outputData = [UInt16](repeating: 0, count: pixelData.count)

        for pixel in sortedPixels {
            
        }
    }
}

class Blob {
    var pixels: [SortablePixel] = []
    var isGrowing: Bool = true
}

struct SortablePixel {
    let x: Int
    let y: Int
    let intensity: UInt16

    init(x: Int = 0,
         y: Int = 0,
         intensity: UInt16 = 0)
    {
        self.x = x
        self.y = x
        self.intensity = intensity
    }
}

fileprivate let fileManager = FileManager.default
