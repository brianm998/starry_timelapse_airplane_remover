/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging
import Cocoa
import Combine

// we derive a Double value from each of these
// all switches on this enum are in this file
// add a new case, handle all switches here, and the
// decision tree generator will use it after recompile
// all existing outlier value files will need to be regenerated to include it
public enum OutlierGroupFeature: String,
                                 CaseIterable,
                                 Hashable,
                                 Codable,
                                 Comparable,
                                 Sendable
{
    case size
    case width
    case height
    case centerX
    case centerY
    case minX
    case minY
    case maxX
    case maxY
    case hypotenuse
    case aspectRatio
    case fillAmount
    case surfaceAreaRatio
    case averagebrightness
    case medianBrightness
    case maxBrightness
    case numberOfNearbyOutliersInSameFrame
    case maxHoughTransformCount
    case pixelBorderAmount
    case averageLineVariance
    case medianLineVariance
    case lineLength

    case nearbyDirectOverlapScore
    case boundingBoxOverlapScore
    case lineFillAmount
    case borderBrightness 

    case bunchCount
    case medianBunchSize
    case maxBunchSize
    
    /*

     add new classification criteria based upon how closely the pixels are bunched:
      - number of unique bunches
      - largest bunch size
      - median bunch size
     */

    
    /*
     XXX add:
     - now that we've gotten good lines out of the KHT, try rewriting the old streak
     detection logic to iterate on an outliers line outside of its bounding box.
     score can be how good a fit is found on either side.  Fit can be determined
     by a combination of size, brightness, and line similarity, 0-1 where 1 is identical.

     */
    
    /*
     add score based upon number of close with hough line histogram values
     add score based upon how many overlapping outliers there are in
     adjecent frames, and how close their thetas are 
     
     some more numbers about hough lines

     add some kind of decision based upon other outliers,
     both within this frame, and in others
     
     */

    public static var allCasesString: String {
        var ret = ""
        for type in OutlierGroupFeature.allCases {
            ret += "\(type.rawValue)\n"
        }

        return ret
    }
    
    public var sortOrder: Int {
        switch self {
        case .size:
            return 0
        case .width:
            return 1
        case .height:
            return 2
        case .centerX:
            return 3
        case .centerY:
            return 4
        case .minX:
            return 5
        case .minY:
            return 6
        case .maxX:
            return 7
        case .maxY:
            return 8
        case .hypotenuse:
            return 9
        case .aspectRatio:
            return 10
        case .fillAmount:
            return 11
        case .surfaceAreaRatio:
            return 12
        case .averagebrightness:
            return 13
        case .medianBrightness:
            return 14
        case .maxBrightness:
            return 15
        case .numberOfNearbyOutliersInSameFrame:
            return 16
        case .maxHoughTransformCount:
            return 17
        case .pixelBorderAmount:
            return 18
        case .averageLineVariance:
            return 19
        case .medianLineVariance:
            return 20
        case .lineLength:
            return 21
        case .nearbyDirectOverlapScore:
            return 22
        case .boundingBoxOverlapScore:
            return 23
        case .lineFillAmount:
            return 24
        case .borderBrightness:
            return 25
        case .bunchCount:
            return 26
        case .medianBunchSize:
            return 27
        case .maxBunchSize:
            return 28
        }
    }

    public func decisionTreeValue(of group: OutlierGroup) async -> Double {
        let height = IMAGE_HEIGHT!
        let width = IMAGE_WIDTH!

        switch self {
        case .size:
            return Double(group.size)/(height*width)
        case .width:
            return Double(group.bounds.width)/width
        case .height:
            return Double(group.bounds.height)/height
        case .centerX:
            return Double(group.bounds.center.x)/width
        case .minX:
            return Double(group.bounds.min.x)/width
        case .maxX:
            return Double(group.bounds.max.x)/width
        case .minY:
            return Double(group.bounds.min.y)/height
        case .maxY:
            return Double(group.bounds.max.y)/height
        case .centerY:
            return Double(group.bounds.center.y)/height
        case .hypotenuse:
            return Double(group.bounds.hypotenuse)/(height*width)
        case .aspectRatio:
            return Double(group.bounds.width) / Double(group.bounds.height)
        case .fillAmount:
            return Double(group.size)/(Double(group.bounds.width)*Double(group.bounds.height))
        case .surfaceAreaRatio:
            return ratioOfSurfaceAreaToSize(of: group.pixels,
                                            and: group.pixelSet,
                                            bounds: group.bounds)
        case .averagebrightness:
            return Double(group.brightness)
        case .medianBrightness:            
            return calculateMedianBrightness(of: group)
        case .maxBrightness:    
            return calculateMaxBrightness(of: group)
        case .maxHoughTransformCount:
            return await calculateMaxHoughTransformCount(of: group)
        case .numberOfNearbyOutliersInSameFrame:
            return await calculateNumberOfNearbyOutliersInSameFrame(of: group)
        case .nearbyDirectOverlapScore:
            return await calculateNearbyDirectOverlapScore(of: group)
        case .boundingBoxOverlapScore:
            return await calculateBoundingBoxOverlapScore(of: group)
        case .pixelBorderAmount:
            return calculatePixelBorderAmount(from: group.pixelSet,
                                              with: group.bounds,
                                              and: group.pixels)
        case .averageLineVariance:
            return await group.averageLineVariance()
        case .medianLineVariance:
            return await group.medianLineVariance()
        case .lineLength:
            if let line = await group.originZeroLine {
                let (_, _length) = await group.averageDistanceAndLineLength(from: line)
                return _length
            } else {
                return 0
            }
        case .lineFillAmount:
            return await calculateLineFillAmount(of: group)
        case .borderBrightness:
            return await calculateBorderBrightness(of: group)
        case .bunchCount:
            return await Double(group.bunchCount())
        case .medianBunchSize:
            return await Double(group.medianBunchSize())
        case .maxBunchSize:
            return await Double(group.maxBunchSize())
        }
    }
    
    public static func ==(lhs: OutlierGroupFeature, rhs: OutlierGroupFeature) -> Bool {
        return lhs.sortOrder == rhs.sortOrder
    }

    public static func <(lhs: OutlierGroupFeature, rhs: OutlierGroupFeature) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
    }        
}

    /*
     - A feature that accounts for empty space along the line
       given a line for the outlier group, what percentage of the pixels
       along that line (withing a small distance) are filled in by the
       outlier group, and what ones are not?  Airplane lines have more
       pixels along the line, random other assortments do not.
       0 if no line or no pixels on line
       1 if all line pixels are filled by this outlier group
     */
fileprivate func calculateLineFillAmount(of group: OutlierGroup) async -> Double
{
    var ret = 0.0
    if let line = await group.line() {
        ret = calculateLineFillAmount(from: line,
                                      with: group.bounds,
                                      and: group.pixels,
                                      and: group.pixelSet)
    }
    return ret
}

internal func calculateLineFillAmount(from line: Line,
                                      with bounds: BoundingBox,
                                      and pixels: [UInt16],
                                      and pixelSet: Set<SortablePixel>) -> Double
{
    let minX = bounds.min.x
    let minY = bounds.min.y
    let (ap1, ap2) = line.twoPoints

    let originZeroLine = Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                                  y: ap1.y+Double(minY)),
                              point2: DoubleCoord(x: ap2.x+Double(minX),
                                                  y: ap2.y+Double(minY)),
                              votes: 0)

    let borders = bounds.intersections(with: originZeroLine.standardLine)
    if borders.count > 1 {
        var linePixels = 0
        
        originZeroLine.iterate(between: borders[0],
                               and: borders[1],
                               numberOfAdjecentPixels: 3)
        { x, y, iterationDirection in
            if hasPixelAt(x: x, y: y, with: bounds, and: pixels) {
                linePixels += 1
            }
        }
        return Double(linePixels)/Double(pixelSet.count)
    } else {
        return 0
    }
}


// x,y origin at 0,0
fileprivate func hasPixelAt(x: Int, y: Int,
                            with bounds: BoundingBox,
                            and pixels: [UInt16]) -> Bool
{
    if x < 0 || y < 0 {
        return false
    } else {
        let index = (y-bounds.min.y)*bounds.width + (x-bounds.min.x)
        if index >= 0,
           index < pixels.count
        {
            return pixels[index] != 0
        } else {
            return false
        }
    }
}

fileprivate func calculateMedianBrightness(of group: OutlierGroup) -> Double {
    var values: [UInt16] = []
    for pixel in group.pixelSet {  
        if pixel.intensity > 0 {
            values.append(pixel.intensity)
        }
    }
    // XXX all zero pixels :(
    if values.count == 0 {
        return 0
    } else {
        return Double(values.sorted()[values.count/2])
    }
}

fileprivate func calculateMaxBrightness(of group: OutlierGroup) -> Double { 
    var max: UInt16 = 0
    for pixel in group.pixelSet {  
        if pixel.intensity > max { max = pixel.intensity }
    }
    return Double(max)
}

fileprivate func calculateMaxHoughTransformCount(of group: OutlierGroup) async -> Double {
    var ret = 0.0
    if let line = await group.line() {
        ret = Double(line.votes)/Double(group.size)
    }

    return ret
}


fileprivate func calculateNumberOfNearbyOutliersInSameFrame(of group: OutlierGroup) async -> Double {
    if let frame = await group.frame,
       let nearbyGroups = await frame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance, of: group)
    {
        return Double(nearbyGroups.count)
    } else {
        fatalError("Died on frame \(group.frameIndex)")
    }

}


// 1.0 if all pixels in this group overlap all pixels of outliers in all neighboring frames
// 0 if none of the pixels overlap
// airplane streaks typically do not overlap the same pixels on neighboring frames
fileprivate func calculateNearbyDirectOverlapScore(of group: OutlierGroup) async -> Double {
    if let frame = await group.frame {
        let pixelCount = group.pixelSet.count
        var matchCount = 0
        let previousFrame = await frame.getPreviousFrame()
        let nextFrame = await frame.getNextFrame()

        for pixel in group.pixelSet {
            let index = pixel.y * Int(IMAGE_WIDTH!) + pixel.x
            if let previousFrame,
               let previousOutlierGroups = await previousFrame.getOutlierGroups(),
               await previousOutlierGroups.outlierImageDataFunc()[index] != 0
            {
                matchCount += 1
            }

            if let nextFrame,
               let nextOutlierGroups = await nextFrame.getOutlierGroups(),
               await nextOutlierGroups.outlierImageDataFunc()[index] != 0
            {
                matchCount += 1
            }
        }

        var numberFrames = 0
        if previousFrame != nil {
            numberFrames += 1
        }
        if nextFrame != nil {
            numberFrames += 1
        }
        if numberFrames == 0 { return 0 }
        return Double(matchCount)/(Double(numberFrames)*Double(pixelCount))
    } else {
        fatalError("NO FRAME for nearbyDirectOverlapScore @ index \(group.frameIndex)")
    }
}


// 0 if no pixels are found withing the bounding box in neighboring frames
// 1 if all pixels withing the bounding box in neighboring frames are filled
// airplane streaks typically do not overlap the same pixels on neighboring frames
fileprivate func calculateBoundingBoxOverlapScore(of group: OutlierGroup) async -> Double {

    if group.bounds.max.y - group.bounds.min.y < 2 { return 0 }
    
    if let frame = await group.frame {
        var matchCount = 0
        var numberFrames = 0

        if let previousFrame = await frame.getPreviousFrame(),
           let previousOutlierGroups = await previousFrame.getOutlierGroups()
        {
            let previousOutlierGroupsOutlierYAxisImageData = await previousOutlierGroups.outlierYAxisImageData
            let previousOutlierGroupsOutlierImageData = await previousOutlierGroups.outlierImageData
            numberFrames += 1
            for y in group.bounds.min.y...group.bounds.max.y {
                if let yAxis = previousOutlierGroupsOutlierYAxisImageData,
                   yAxis[y] == 0 { continue }
                
                for x in group.bounds.min.x...group.bounds.max.x {
                    let index = y*Int(IMAGE_WIDTH!) + x
                    if previousOutlierGroupsOutlierImageData[index] != 0 {
                        // there is an outlier here
                        matchCount += 1
                    }
                }
            }
        }
        if let nextFrame = await frame.getNextFrame(),
           let nextOutlierGroups = await nextFrame.getOutlierGroups()
        {
            let nextOutlierGroupsOutlierYAxisImageData = await nextOutlierGroups.outlierYAxisImageData
            let nextOutlierGroupsOutlierImageData = await nextOutlierGroups.outlierImageData
            numberFrames += 1
            for y in group.bounds.min.y...group.bounds.max.y {
                if let yAxis = nextOutlierGroupsOutlierYAxisImageData,
                   yAxis[y] == 0 { continue }
                
                for x in group.bounds.min.x...group.bounds.max.x {
                    let index = y*Int(IMAGE_WIDTH!) + x
                    if nextOutlierGroupsOutlierImageData[index] != 0 {
                        // there is an outlier here
                        matchCount += 1
                    }
                }
            }
        }

        if numberFrames == 0 { return 0 }
        return Double(matchCount)/(Double(numberFrames)*Double(group.bounds.width*group.bounds.height))
    } else {
        fatalError("NO FRAME for boundingBoxOverlapScore @ index \(group.frameIndex)")
    }
}
    

    // how many neighors does each of the pixels in this outlier group have?
    // higher numbers mean they are packed closer together
    // lower numbers mean they are more of a disparate cloud

fileprivate func calculatePixelBorderAmount(from pixelSet: Set<SortablePixel>,
                                            with bounds: BoundingBox,
                                            and pixels: [UInt16]) -> Double {
    var totalNeighbors: Double = 0.0
    var totalSize: Int = 0

    for pixel in pixelSet {
        let x = pixel.x - bounds.min.x
        let y = pixel.y - bounds.min.y
        
        totalSize += 1

        var leftIndex = x - 1
        var rightIndex = x + 1
        var topIndex = y - 1
        var bottomIndex = y + 1
        if leftIndex < 0 { leftIndex = 0 }
        if topIndex < 0 { topIndex = 0 }
        if rightIndex >= bounds.width { rightIndex = bounds.width - 1 }
        if bottomIndex >= bounds.height { bottomIndex = bounds.height - 1 }

        for neighborX in leftIndex...rightIndex {
            for neighborY in topIndex...bottomIndex {
                if neighborX != x,
                   neighborY != y,
                   pixels[neighborY*bounds.width + neighborX] != 0
                {
                    totalNeighbors += 1
                }
            }
        }
    }
    return totalNeighbors/Double(totalSize)
}

fileprivate func calculateBorderBrightness(of group: OutlierGroup) async -> Double {
    if let frame = await group.frame {
        do {
            let accessor = frame.imageAccessor
            if let originalImage = try await accessor.loadFinal(type: .original,
                                                                atSize: .original)
            {
                return originalImage.borderBrightness(of: group.pixelSet)
            }
        } catch {
            Log.e("error calculating border brightness: \(error)")
        }
    }
    return 3.1415926535897 // XXX over 1.0 is a bad value, airplanes are closer to 0.1
}


public func ratioOfSurfaceAreaToSize(of pixels: [UInt16],
                                     and pixelSet: Set<SortablePixel>,
                                     bounds: BoundingBox) -> Double
{
    let width = bounds.width
    let height = bounds.height
    var size: Int = 0
    var surfaceArea: Int = 0
    for pixel in pixelSet {
        let x = pixel.x - bounds.min.x
        let y = pixel.y - bounds.min.y

        size += 1

        var hasTopNeighbor = false
        var hasBottomNeighbor = false
        var hasLeftNeighbor = false
        var hasRightNeighbor = false
        
        if x > 0 {
            if pixels[y * width + x - 1] != 0 {
                hasLeftNeighbor = true
            }
        }
        if y > 0 {
            if pixels[(y - 1) * width + x] != 0 {
                hasTopNeighbor = true
            }
        }
        if x + 1 < width {
            if pixels[y * width + x + 1] != 0 {
                hasRightNeighbor = true
            }
        }
        if y + 1 < height {
            if pixels[(y + 1) * width + x] != 0 {
                hasBottomNeighbor = true
            }
        }
        
        if hasTopNeighbor,
           hasBottomNeighbor,
           hasLeftNeighbor,
           hasRightNeighbor
        {
            
        } else {
            surfaceArea += 1
        }

    }
    return Double(surfaceArea)/Double(size)
}

