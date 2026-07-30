/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import StarCppBridge
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

        // Seed the flood fills in row major order rather than in `pixelSet`'s hash order.
        // Which pixel a bunch is discovered from does not change the partition — the
        // neighbourhood below is symmetric, so this is a plain connected components pass —
        // but it does decide the order of the returned array, and Set iteration order is not
        // guaranteed to be stable between processes.  bunchCount, medianBunchSize and
        // maxBunchSize are all decision-tree features, so a run has to be reproducible.
        let seeds = pixelSet.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }

        for pixel in seeds {
            if !handledPixels.contains(pixel) {
                handledPixels.update(with: pixel)

                var newBunch: Set<SortablePixel> = []

                var nearbyPixels: [SortablePixel] = [pixel]

                while nearbyPixels.count > 0 {
                    let nextPixel = nearbyPixels.removeFirst()
                    newBunch.update(with: nextPixel)

                    // Every pixel within maxPixelDistance+1 in either direction joins this
                    // bunch, so maxPixelDistance is the number of empty pixels tolerated
                    // between two members and the default of 0 means the eight touching
                    // neighbours.
                    //
                    // The upper bounds are +2 because the loops below are half open: the
                    // furthest index reached is maxX-1, so maxX has to be one past the
                    // pixel we mean to include.  They used to be +1, which made the window
                    // reach maxPixelDistance+1 backwards but only maxPixelDistance forwards.
                    // A gap of exactly maxPixelDistance+1 then merged or not depending on
                    // which end the flood fill happened to start from, and with the seed
                    // order coming from a Set that made the three bunch features
                    // non-deterministic between runs of the same frame.
                    var minX = nextPixel.x - bounds.min.x - maxPixelDistance - 1
                    if minX < 0 { minX = 0 }

                    var maxX = nextPixel.x - bounds.min.x + maxPixelDistance + 2
                    if maxX > bounds.width { maxX = bounds.width }

                    var minY = nextPixel.y - bounds.min.y - maxPixelDistance - 1
                    if minY < 0 { minY = 0 }

                    var maxY = nextPixel.y - bounds.min.y + maxPixelDistance + 2
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
