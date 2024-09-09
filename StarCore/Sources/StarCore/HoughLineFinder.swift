/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging

public protocol AbstractPixel {
    var x: Int { get }
    var y: Int { get }
}

fileprivate enum DataType {
    // row major image data
    case rowMajor([UInt16])

    // a random list of x,y pixels
    case list([AbstractPixel])
}

// use the KHT to find lines, and then return the one which best fits the input data,
// i.e. has the lowest mean distance of pixels to the line
public struct HoughLineFinder {

    fileprivate let data: DataType
    let bounds: BoundingBox
    
    public init(pixels: [UInt16], bounds: BoundingBox) {
        data = .rowMajor(pixels)
        self.bounds = bounds
    }

    public init(pixels: [AbstractPixel], bounds: BoundingBox) {
        data = .list(pixels)
        self.bounds = bounds
    }
    
    let imageDataBorderSize = 80

    public var imageDataWidth: Int {
        self.bounds.width+imageDataBorderSize*6
    }

    public var imageDataHeight: Int {
        self.bounds.height+imageDataBorderSize*6
    }

    public var imageData: [UInt8] {
        var imageData = [UInt8](repeating: 0, count: self.imageDataWidth * self.imageDataHeight)
        
        //Log.d("frame \(frameIndex) blob image data with \(pixels.count) pixels")
        
        let minX = self.bounds.min.x
        let minY = self.bounds.min.y
        switch data {
        case .list(let pixels):
            for pixel in pixels {
                let imageIndex = (pixel.y - minY + imageDataBorderSize)*imageDataWidth + 
                  (pixel.x - minX + imageDataBorderSize)
                imageData[imageIndex] = 0xFF
            }

        case .rowMajor(let pixels):
            for x in 0..<self.bounds.width {
                for y in 0..<self.bounds.height {
                    let index = y*self.bounds.width+x
                    if pixels[index] > 0 {
                        let imageIndex = (y + imageDataBorderSize)*imageDataWidth + 
                          (x + imageDataBorderSize)

                        if imageIndex < 0 || imageIndex >= imageData.count {
                            fatalError("from [\(x), \(y)] and \(self.bounds) BAD IMAGEINDEX \(imageIndex) for imageData.count \(imageData.count)")
                        }
                        
                        imageData[imageIndex] = 0xFF
                    }
                }
            }
        }
        return imageData
    }

    public var line: Line? {
        let imageData = self.imageData
        let pixelImage = PixelatedImage(width: self.imageDataWidth,
                                        height: self.imageDataHeight,
                                        grayscale8BitImageData: imageData)

        if let image = pixelImage.nsImage {
            let lines = kernelHoughTransform(image: image,
                                             maxResults: OutlierGroup.numberOfLinesToReturn) // XXX move this constant here
            for (index, line) in lines.enumerated() {
                Log.d("line \(index): \(line)")
            }

            /*
                - look at the first N lines (10?)
                - calculate the average distance from the line for each of them.
                - choose the best one
             */

            if lines.count > 0 {
                var linesToConsider = OutlierGroup.numberOfLinesToConsider
                if linesToConsider > lines.count { linesToConsider = lines.count }

                var closestDistance: Double = 9999999999
                var bestLineIndex = 0
                
                for i in 0..<linesToConsider {
                    let originZeroLine = self.originZeroLine(from: lines[i])

                    let (avg, median, max) = self.averageMedianMaxDistance(from: originZeroLine)
                    
                    Log.d("line \(i) theta \(lines[i].theta) avg median max \(avg) \(median) \(max)")
                    if median < closestDistance {
                        Log.d("line \(i) is best")
                        closestDistance = median
                        bestLineIndex = i
                    }
                }

                return lines[bestLineIndex]
            }
        }
        return nil
    }

    public func averageMedianMaxDistance(from line: Line) -> (Double, Double, Double) {
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        var distances:[Double] = []
        var max: Double = 0
        var numPixels: Int = 0
        switch data {
        case .list(let pixels):
            numPixels = pixels.count
            for pixel in pixels {
                let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                distanceSum += distance
                distances.append(distance)
                if distance > max { max = distance }                
            }
        case .rowMajor(let pixels):
            for x in 0..<self.bounds.width {
                for y in 0..<self.bounds.height {
                    let index = y*self.bounds.width+x
                    if pixels[index] > 0 {
                        numPixels += 1
                        let distance = standardLine.distanceTo(x: x, y: y)
                        distanceSum += distance
                        distances.append(distance)
                        if distance > max { max = distance }
                    }
                }
            }
        }
        distances.sort { $0 > $1 }
        if numPixels == 0 {
            return (0, 0, 0)
        } else {
            let average = distanceSum/Double(numPixels)
            let median = distances[distances.count/2]
            return (average, median, max)
        }
    }

    public func originZeroLine(from line: Line) -> Line {
        let minX = self.bounds.min.x - imageDataBorderSize
        let minY = self.bounds.min.y - imageDataBorderSize
        let (ap1, ap2) = line.twoPoints
        return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                        y: ap1.y+Double(minY)),
                    point2: DoubleCoord(x: ap2.x+Double(minX),
                                        y: ap2.y+Double(minY)),
                    votes: 0)
    }
    
}
