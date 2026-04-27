/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging

public enum TreeType: String, CaseIterable, Sendable {
    case all
    case isolated

    public static var allCasesString: String {
        var ret = ""
        for type in TreeType.allCases {
            ret += "\(type.rawValue)\n"
        }

        return ret
    }
}

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
    case lineIntensityScore
    case linePixelScore
    case borderBrightness

    case bunchCount
    case medianBunchSize
    case maxBunchSize

    case neighborLineThetaScore
    case neighborLineRhoScore
    case neighborLineSizeScore
    case neighborLineBrightnessScore
    case neighborLineDistanceScore
    
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
    
    public func isUsed(for treeType: TreeType) -> Bool {
        switch treeType {
        case .all:
            return true

        case .isolated:
            switch self {
            case .numberOfNearbyOutliersInSameFrame:
                return false
            case .nearbyDirectOverlapScore:
                return false
            case .boundingBoxOverlapScore:
                return false
            case .borderBrightness:
                return false
            case .neighborLineThetaScore:
                return false
            case .neighborLineRhoScore:
                return false
            case .neighborLineSizeScore:
                return false
            case .neighborLineBrightnessScore:
                return false
            case .neighborLineDistanceScore:
                return false
                
            default:
                return true
            }
        }
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
        case .lineIntensityScore:
            return 24
        case .borderBrightness:
            return 25
        case .bunchCount:
            return 26
        case .medianBunchSize:
            return 27
        case .maxBunchSize:
            return 28
        case .neighborLineThetaScore:
            return 29
        case .neighborLineRhoScore:
            return 30
        case .neighborLineSizeScore:
            return 31
        case .neighborLineBrightnessScore:
            return 32
        case .neighborLineDistanceScore:
            return 33
        case .linePixelScore:
            return 34
        }
    }

    public var isAsync: Bool {
        switch self {
        case .size:
            return false
        case .width:
            return false
        case .height:
            return false
        case .centerX:
            return false
        case .minX:
            return false
        case .maxX:
            return false
        case .minY:
            return false
        case .maxY:
            return false
        case .centerY:
            return false
        case .hypotenuse:
            return false
        case .aspectRatio:
            return false
        case .fillAmount:
            return false
        case .surfaceAreaRatio:
            return false
        case .averagebrightness:
            return false
        case .medianBrightness:            
            return false
        case .maxBrightness:    
            return false
        case .maxHoughTransformCount: 
            return true
        case .pixelBorderAmount:
            return false
        case .averageLineVariance: 
            return true
        case .medianLineVariance: 
            return true
        case .lineLength:    
            return true
        case .lineIntensityScore:
            return true
        case .linePixelScore:
            return true
        case .bunchCount:    
            return true
        case .medianBunchSize:
            return true
        case .maxBunchSize:   
            return true

        // all cases after here are not used for .isolated trees
        case .borderBrightness:
            return true
        case .numberOfNearbyOutliersInSameFrame:
            return true
        case .nearbyDirectOverlapScore: 
            return true
        case .boundingBoxOverlapScore:
            return true
        case .neighborLineThetaScore: 
            return true
        case .neighborLineRhoScore:
            return true
        case .neighborLineSizeScore:
            return true
        case .neighborLineBrightnessScore:
            return true
        case .neighborLineDistanceScore:
            return true
        }
    }
    
    public func decisionTreeValue(of group: OutlierGroup) async -> Double {
        let height = IMAGE_HEIGHT!
        let width = IMAGE_WIDTH!

        switch self {
        case .maxHoughTransformCount: // depends upon group.line
            return await calculateMaxHoughTransformCount(of: group)

        case .averageLineVariance: // depends upon group.line for properties
            return await group.averageLineVariance()
        case .medianLineVariance: // depends upon group.line for properties
            return await group.medianLineVariance()
        case .lineLength:    // depends upon group.line for properties
            if let line = await group.originZeroLine {
                let (_, _length) = await group.averageDistanceAndLineLength(from: line)
                return _length
            } else {
                return 0
            }

        case .lineIntensityScore:   // depends upon group.line for properties
            return await group.getLineIntensityScore() ?? 0

        case .linePixelScore:   // depends upon group.line for properties
            return await group.getLinePixelScore() ?? 0

        case .bunchCount:       // depends upon pixel set
            return await Double(group.bunchCount())
        case .medianBunchSize:  // depends upon pixel set
            return await Double(group.medianBunchSize())
        case .maxBunchSize:     // depends upon pixel set
            return await Double(group.maxBunchSize())

        // all cases after here are not used for .isolated trees
        case .borderBrightness: // depends upon the original image
            return await calculateBorderBrightness(of: group)
        case .numberOfNearbyOutliersInSameFrame: // depends upon outlierGroups
            return await calculateNumberOfNearbyOutliersInSameFrame(of: group, in: group.frame?.outlierGroups)

        case .nearbyDirectOverlapScore: // depends upon previous and next frames, outlierImageDataFunc
            var prevImgData: FrameHolder?
            if let arr = await group.frame?.getPreviousFrame()?.getOutlierGroups()?.outlierImageDataFunc() {
                prevImgData = FrameHolder(arr, width: Int(width), height: Int(height))
            }
            
            var nextImgData: FrameHolder?
            if let arr = await group.frame?.getNextFrame()?.getOutlierGroups()?.outlierImageDataFunc() {
                nextImgData = FrameHolder(arr, width: Int(width), height: Int(height))
            }
            return calculateNearbyDirectOverlapScore(of: group,
                                                     previousImageData: prevImgData,
                                                     nextImageData: nextImgData)

        case .boundingBoxOverlapScore: // depends upon previous and next frames, outlierImageData
            var prevImgData: FrameHolder?
            if let arr = await group.frame?.getPreviousFrame()?.getOutlierGroups()?.outlierImageDataFunc() {
                prevImgData = FrameHolder(arr, width: Int(width), height: Int(height))
            }
            
            var nextImgData: FrameHolder?
            if let arr = await group.frame?.getNextFrame()?.getOutlierGroups()?.outlierImageDataFunc() {
                nextImgData = FrameHolder(arr, width: Int(width), height: Int(height))
            }
            
            return calculateBoundingBoxOverlapScore(of: group,
                                                    previousImageData: prevImgData,
                                                    nextImageData: nextImgData)

        case .neighborLineThetaScore: // these all depend upon the previous and next outlierImageData
            return await group.neighboringThetaScore
        case .neighborLineRhoScore:
            return await group.neighboringRhoScore
        case .neighborLineSizeScore:
            return await group.neighboringSizeScore
        case .neighborLineBrightnessScore:
            return await group.neighboringBrightnessScore
        case .neighborLineDistanceScore:
            return await group.neighboringDistanceScore
        default:
            return decisionTreeValueSync(of: group)
        }
    }
    
    public func decisionTreeValueSync(of group: OutlierGroup) -> Double {
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
        case .maxHoughTransformCount: // depends upon group.line
            fatalError("call decisionTreeValue for this type")

        case .pixelBorderAmount:
            return calculatePixelBorderAmount(from: group.pixelSet,
                                              with: group.bounds,
                                              and: group.pixels)
        case .averageLineVariance: // depends upon group.line for properties
            fatalError("call decisionTreeValue for this type")

        case .medianLineVariance: // depends upon group.line for properties
            fatalError("call decisionTreeValue for this type")

        case .lineLength:    // depends upon group.line for properties
            fatalError("call decisionTreeValue for this type")

        case .lineIntensityScore:   // depends upon group.line for properties
            fatalError("call decisionTreeValue for this type")
        case .linePixelScore:
            fatalError("call decisionTreeValue for this type")
        case .bunchCount:       // depends upon pixel set
            fatalError("call decisionTreeValue for this type")
        case .medianBunchSize:  // depends upon pixel set
            fatalError("call decisionTreeValue for this type")
        case .maxBunchSize:     // depends upon pixel set
            fatalError("call decisionTreeValue for this type")

        // all cases after here are not used for .isolated trees
        case .borderBrightness: // depends upon the original image
            fatalError("call decisionTreeValue for this type")

        case .numberOfNearbyOutliersInSameFrame: // depends upon outlierGroups
            fatalError("call decisionTreeValue for this type")
            
        case .nearbyDirectOverlapScore: // depends upon previous and next frames, outlierImageDataFunc
            fatalError("call decisionTreeValue for this type")
        case .boundingBoxOverlapScore: // depends upon previous and next frames, outlierImageData
            fatalError("call decisionTreeValue for this type")
        case .neighborLineThetaScore: // these all depend upon the previous and next outlierImageData
            fatalError("call decisionTreeValue for this type")
        case .neighborLineRhoScore:
            fatalError("call decisionTreeValue for this type")
        case .neighborLineSizeScore:
            fatalError("call decisionTreeValue for this type")
        case .neighborLineBrightnessScore:
            fatalError("call decisionTreeValue for this type")
        case .neighborLineDistanceScore:
            fatalError("call decisionTreeValue for this type")
        }
    }
    
    public static func ==(lhs: OutlierGroupFeature, rhs: OutlierGroupFeature) -> Bool {
        return lhs.sortOrder == rhs.sortOrder
    }

    public static func <(lhs: OutlierGroupFeature, rhs: OutlierGroupFeature) -> Bool {
        return lhs.sortOrder < rhs.sortOrder
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
            values.append(pixel.uInt16Value)
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
        if pixel.uInt16Value > max { max = pixel.uInt16Value }
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


internal func calculateNumberOfNearbyOutliersInSameFrame(of group: OutlierGroup,
                                                         in outlierGroups: OutlierGroups?) async -> Double
{
    guard let outlierGroups else { return  0 }
    let nearbyGroups = await outlierGroups.groups(nearby: group, within: 80) // XXX hardcoded constant
    return Double(nearbyGroups.count)
}

// 1.0 if all pixels in this group overlap all pixels of outliers in all neighboring frames
// 0 if none of the pixels overlap
// airplane streaks typically do not overlap the same pixels on neighboring frames
internal func calculateNearbyDirectOverlapScore(of group: OutlierGroup,
                                                previousImageData: FrameHolder?,
                                                nextImageData: FrameHolder?) -> Double
{
    let pixelCount = group.pixelSet.count
    var matchCount = 0

    for pixel in group.pixelSet {
        if let previousImageData,
           previousImageData.value(at: pixel.x, and: pixel.y) != 0
        {
            matchCount += 1
        }

        if let nextImageData,
           nextImageData.value(at: pixel.x, and: pixel.y) != 0
        {
            matchCount += 1
        }
    }

    var numberFrames = 0
    if previousImageData != nil {
        numberFrames += 1
    }
    if nextImageData != nil {
        numberFrames += 1
    }
    if numberFrames == 0 { return 0 }
    return Double(matchCount)/(Double(numberFrames)*Double(pixelCount))
}


// 0 if no pixels are found withing the bounding box in neighboring frames
// 1 if all pixels withing the bounding box in neighboring frames are filled
// airplane streaks typically do not overlap the same pixels on neighboring frames
internal func calculateBoundingBoxOverlapScore(of group: OutlierGroup,
                                               previousImageData: FrameHolder?,
                                               nextImageData: FrameHolder?) -> Double
{
    if group.bounds.max.y - group.bounds.min.y < 2 { return 0 }
    
    var matchCount = 0
    var numberFrames = 0

    if let previousImageData {
        numberFrames += 1
        for y in group.bounds.min.y...group.bounds.max.y {
            for x in group.bounds.min.x...group.bounds.max.x {
                if previousImageData.value(at: x, and: y) != 0 {
                    // there is an outlier here
                    matchCount += 1
                }
            }
        }
    }
    if let nextImageData {
        numberFrames += 1
        for y in group.bounds.min.y...group.bounds.max.y {
            for x in group.bounds.min.x...group.bounds.max.x {
                if nextImageData.value(at: x, and: y) != 0 {
                    // there is an outlier here
                    matchCount += 1
                }
            }
        }
    }

    if numberFrames == 0 { return 0 }
    return Double(matchCount)/(Double(numberFrames)*Double(group.bounds.width*group.bounds.height))
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
            if let originalImage =
                 try await accessor.loadFinal(frameIndex: frame.frameIndex,
                                              type: .original,
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


