/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging

fileprivate struct LineSplitResult {
    let score: Double
    let line: Line
}

// use the KHT to find lines, and then return the one which best fits the input data,
// i.e. has the lowest mean distance of pixels to the line
public struct HoughLineFinder {

    let data: [SortablePixel]
    let bounds: BoundingBox
    let medianIntensity: UInt16
    let maxIntensity: UInt16
    let frameIndex: Int

    public init(pixels: [SortablePixel],
                bounds: BoundingBox,
                medianIntensity: UInt16,
                maxIntensity: UInt16,
                frameIndex: Int)
    {
        data = pixels
        self.bounds = bounds
        self.frameIndex = frameIndex
        self.maxIntensity = maxIntensity
        self.medianIntensity = medianIntensity
    }
    
    // it's best to keep the important pixel data away from the middle of the image,
    // as the KHT uses the center of the image as the origin for its lines.
    // we get better results this way, instead of giving the KHT algorithm a small image with a
    // line right through the middle of it
    
    let imageDataBorderSize = 80
    
    public var imageDataWidth: Int {
        self.bounds.width+imageDataBorderSize*6
    }

    public var imageDataHeight: Int {
        self.bounds.height+imageDataBorderSize*6
    }

    public func imageData(ignoringPixlesDimmerThan minIntensity: UInt16 = 0) -> [UInt8] {
        var imageData = [UInt8](repeating: 0, count: self.imageDataWidth * self.imageDataHeight)
        
        //Log.d("frame \(frameIndex) blob image data with \(pixels.count) pixels")
        
        let minX = self.bounds.min.x
        let minY = self.bounds.min.y

        for pixel in data {
            if pixel.intensity > minIntensity {
                let imageIndex = (pixel.y - minY)*imageDataWidth + 
                  (pixel.x - minX)
                //imageData[imageIndex] = 0xFF
                imageData[imageIndex] = UInt8(pixel.intensity>>8)
            }
        }

        return imageData
    }

    public struct LineSplitArgs: Sendable {
        let maxLines: Int        // max number of lines to look at
        let maxDistance: Double  // pixels at least this far away from a line give zero score
        let minLineScore: Double // sub lines must have at least this score to be included
        let minLineCount: Int    // sub lines must have at least this number of pixels

        public init(
          maxLines: Int = 8000,  
          maxDistance: Double = 8,
          minLineScore: Double = 12,
          minLineCount: Int = 10
        ) {
            self.maxLines = maxLines
            self.maxDistance = maxDistance
            self.minLineScore = minLineScore
            self.minLineCount = minLineCount
        }
    }
    
    // iterate through all lines and see if any of them have a match
    // with a certain number of pixels.
    // If so, sort them by number of closest pixels, and iterate over
    // them to split this group out into more than one
    public func lineSplit(args: LineSplitArgs, optimalLine: Line?)
      -> ([SortablePixel], [[SortablePixel]])
      // first return value is the original, possibly reduced, set of pixels we started with
      // the second return value is a list of any sub-blobs we found that are close to another line
    {

        let pixelImage = self.pixelImage
        if let image = pixelImage.nsImage {
            let lines = kernelHoughTransform(image: image, maxResults: args.maxLines)
            if lines.count > 0 {
                var max = lines.count
                if max > args.maxLines { max = args.maxLines } 

                var results: [LineSplitResult] = []
                
                for i in 0..<max {
                    /*
                     call a function here to see many pixels are close to this
                     line

                     a per pixel score where 1 means on line,
                     0 means X pixels from line
                     score for line is sum of values for all pixels

                     return a sortable struct that we can sort by
                     number of close pixels (over some threshold),
                     and then iterate over that to split up this group up
                     */
                    
                    let originZeroLine = self.originZeroLine(from: lines[i])
                    let linePixelScore = pixelScore(for: originZeroLine,
                                                    maxDistance: args.maxDistance)

                    if linePixelScore > args.minLineScore {
                        results.append(LineSplitResult(score: linePixelScore,
                                                       line: originZeroLine))

                    }
                }

                let sortedResults = results.sorted() { $0.score > $1.score } 

                var linesToProcess: [Line] = []
                if let optimalLine { linesToProcess.append(optimalLine) }

                let minThetaDiff: Double = 10 // XXX degrees XXX should be parameter
                let minRhoDiff: Double = 10
                
                if sortedResults.count > 0 {
                    // we found at least one sorted result
                    var pixelsForLines: [Line:[SortablePixel]] = [:]
                    var pixelsToKeep: Set<SortablePixel> = Set(data)

                    // filter out lines with similar theta
                    for result in sortedResults {
                        var shouldProcessThisLine = true

                        for existingLine in linesToProcess {
                            if abs(existingLine.theta-result.line.theta) < minThetaDiff || 
                               abs(existingLine.rho-result.line.rho) < minRhoDiff
                            {
                                shouldProcessThisLine = false
                                break
                            }
                        }
                        
                        if shouldProcessThisLine {
                            linesToProcess.append(result.line)
                        }
                    }

                    //Log.d("frame \(frameIndex) linesToProcess \(linesToProcess)")

                    for line in linesToProcess {
                        let standardLine = line.standardLine
                        for pixel in pixelsToKeep {
                            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                            if distance < 12 { // XXX constant should be arg

                                // this line gets this pixel
                                if var pixelList = pixelsForLines[line] {
                                    pixelList.append(pixel)
                                    pixelsForLines[line] = pixelList
                                } else {
                                    pixelsForLines[line] = [pixel]
                                }
                                pixelsToKeep.remove(pixel)
                            }
                        }
                    }

                    var newPixelSets: [[SortablePixel]] = []

                    var pixelArrayToKeep = Array(pixelsToKeep)
                    
                    for (_, pixelList) in pixelsForLines {
                        if pixelList.count >= args.minLineCount { 
                            newPixelSets.append(pixelList)
                        } else {
                            pixelArrayToKeep.append(contentsOf: pixelList)
                        }
                    }
                    return (pixelArrayToKeep, newPixelSets)
                }
            }
        }

        return ([], [])
    }

    public func pixelScore(for line: Line, maxDistance: Double = 5) -> Double {
        let standardLine = line.standardLine
        var ret: Double = 0.0
        for pixel in data {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            if distance <= maxDistance {
                // 0 for maxDistance or furter from the line
                // 1 for spot on the line
                ret += ((maxDistance-distance)/maxDistance)*Double(pixel.intensity)
            }
        }
        return ret
    }
    
    var pixelImage: PixelatedImage {
        if medianIntensity != 0,
           maxIntensity/medianIntensity > 2
        {
            let imageData = self.imageData(ignoringPixlesDimmerThan: medianIntensity)
            return PixelatedImage(width: self.imageDataWidth,
                                  height: self.imageDataHeight,
                                  grayscale8BitImageData: imageData)
        } else {
            let imageData = self.imageData()
            return PixelatedImage(width: self.imageDataWidth,
                                  height: self.imageDataHeight,
                                  grayscale8BitImageData: imageData)
        }
     }
    
    public var line: Line? {
        let pixelImage = self.pixelImage
        
        let maxLineConstant = 800 // XXX constant for how many lines to look at
        
        if let image = pixelImage.nsImage {
            let lines = kernelHoughTransform(image: image, maxResults: maxLineConstant)
//            for (index, line) in lines.enumerated() {
//                Log.d("line \(index): \(line)")
//            }

            /*
                - look at the first N lines
                - calculate the average distance from the line for each of them.
                - choose the best one
             */

            if lines.count > 0 {
                var bestScore: Double = 0
                var bestLineIndex = 0
                var max = lines.count
                if max > maxLineConstant { max = maxLineConstant } 
                
                for i in 0..<max {
                    let originZeroLine = self.originZeroLine(from: lines[i])

                    let lineScore = pixelScore(for: originZeroLine,
                                               maxDistance: 24)
                    
                    if lineScore > bestScore {
                        //Log.d("line \(i) is best theta \(lines[i].theta) avg median max \(avg) \(median) \(max)")
                        bestScore = lineScore
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

        numPixels = data.count
        for pixel in data {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            distanceSum += distance
            distances.append(distance)
            if distance > max { max = distance }                
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
        let minX = self.bounds.min.x
        let minY = self.bounds.min.y
        let (ap1, ap2) = line.twoPoints
        return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                        y: ap1.y+Double(minY)),
                    point2: DoubleCoord(x: ap2.x+Double(minX),
                                        y: ap2.y+Double(minY)),
                    votes: 0)
    }
    
}
