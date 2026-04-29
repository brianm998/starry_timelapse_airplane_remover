/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import StarCpp
import logging

// how far pixels have to be from eachother to be considered as separate bunch
public let maxBunchDistance: Int = 2

// returns bunches of pixles that are no more than maxPixelDistance from eachother

// returns number of bunches, median bunch size, max bunch size
public func calculateBunchData(from blob: Blob,
                               maxPixelDistance: Int = 0) async -> (Int, Int, Int)
{
    calculateBunchData(from: await blob.pixels,
                       with: await blob.boundingBox(),
                       maxPixelDistance: maxPixelDistance)
}

// returns number of bunches, median bunch size, max bunch size
public func calculateBunchData(from group: OutlierGroup,
                               maxPixelDistance: Int = 0) -> (Int, Int, Int)
{
    calculateBunchData(from: group.pixelSet,
                       with: group.bounds,
                       maxPixelDistance: maxPixelDistance)
}

private func calculateBunchData(from pixelSet: Set<SortablePixel>,
                                with bounds: BoundingBox,
                                maxPixelDistance: Int = 0) -> (Int, Int, Int)
{
    let bunchCalculator = BunchCalculator(from: pixelSet,
                                          with: bounds,
                                          maxPixelDistance: maxPixelDistance)

    // XXX move list of bunches into Blob so we can filter pixels by bunch in
    // the blob processor
    let bunches = bunchCalculator.calculateBunches()

    var largestSize: Int = 0
    var sizeList: [Int] = []
    for bunch in bunches {
        sizeList.append(bunch.count)
        if bunch.count > largestSize { largestSize = bunch.count }
    }
    let sortedSizes = sizeList.sorted()
    let medianIndex = sortedSizes.count/2
    var medianSize = 0
    if medianIndex < sortedSizes.count {
        medianSize = sortedSizes[medianIndex]
    }
    return (bunches.count, medianSize, largestSize)
}

public class BunchCalculator {
    let pixelSet: Set<SortablePixel>
    let bounds: BoundingBox
    let pixels: [SortablePixel?] // row major indexed two dimentional array 
    let maxPixelDistance: Int

    var bunches: [Set<UInt16>] = []
    var handledPixels: Set<SortablePixel> = []
    
    public init(from pixelSet: Set<SortablePixel>,
                with bounds: BoundingBox,
                maxPixelDistance: Int = 0)
    {
        var _pixels = [SortablePixel?](repeating: nil, count: bounds.width*bounds.height)
        for pixel in pixelSet {
            let index = (pixel.y-bounds.min.y)*bounds.width+(pixel.x-bounds.min.x)
            _pixels[index] = pixel
        }
        self.pixels = _pixels
        self.pixelSet = pixelSet
        self.bounds = bounds
        self.maxPixelDistance = maxPixelDistance
    }

    public func calculateBunches() -> [Set<SortablePixel>] {
        var ret: [Set<SortablePixel>] = []
        for pixel in pixelSet {
            if !handledPixels.contains(pixel) {
                handledPixels.update(with: pixel)

                var newBunch: Set<SortablePixel> = []
                
                var nearbyPixels: [SortablePixel] = [pixel]

                while nearbyPixels.count > 0 {
                    let nextPixel = nearbyPixels.removeFirst()
                    newBunch.update(with: nextPixel)

                    var minX = nextPixel.x - bounds.min.x - maxPixelDistance - 1
                    if minX < 0 { minX = 0 }

                    var maxX = nextPixel.x - bounds.min.x + maxPixelDistance + 1
                    if maxX > bounds.width { maxX = bounds.width }

                    var minY = nextPixel.y - bounds.min.y - maxPixelDistance - 1
                    if minY < 0 { minY = 0 }

                    var maxY = nextPixel.y - bounds.min.y + maxPixelDistance + 1
                    if maxY > bounds.height { maxY = bounds.height }

                    for x in minX..<maxX {
                        for y in minY..<maxY {
                            let index = y*bounds.width+x
                            if let newPixel = pixels[index],
                               !handledPixels.contains(newPixel)
                            {
                                nearbyPixels.append(newPixel)
                                handledPixels.update(with: newPixel)
                            }
                        }
                    }
                }
                ret.append(newBunch)
            }
        }
        return ret
    }
}
