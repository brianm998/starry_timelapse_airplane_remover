/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// https://stackoverflow.com/questions/63018581/fastest-way-to-save-structs-ios-swift
// XXX look into ContiguousBytes

import Foundation
import Cocoa

// these need to be setup at startup so the decision tree values are right
internal var IMAGE_WIDTH: Double?
internal var IMAGE_HEIGHT: Double?

// represents a single outler group in a frame
public class OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable
{
    public let name: String
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public let lines: [Line]           // sorted lines from the hough transform of this outlier group

    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    public let pixels: [UInt32]        // indexed by y * bounds.width + x

    public let maxPixelDistance: UInt16
    public let surfaceAreaToSizeRatio: Double

    // after init, shouldPaint is usually set to a base value based upon different statistics 
    public var shouldPaint: PaintReason? // should we paint this group, and why?

    public let frameIndex: Int

    // has to be optional so we can read OuterlierGroups as codable
    public var frame: FrameAirplaneRemover?

    public func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }
    
    // returns the first, most likely line, if any
    var firstLine: Line? {
        if lines.count > 0 {
            return lines[0]
        }
        return nil
    } 

    init(name: String,
         size: UInt,
         brightness: UInt,      // average brightness
         bounds: BoundingBox,
         frame: FrameAirplaneRemover,
         pixels: [UInt32],
         maxPixelDistance: UInt16) async
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frameIndex = frame.frameIndex
        self.frame = frame
        self.pixels = pixels
        self.maxPixelDistance = maxPixelDistance
        self.surfaceAreaToSizeRatio = ratioOfSurfaceAreaToSize(of: pixels,
                                                               width: bounds.width,
                                                               height: bounds.height)
        // do a hough transform on just this outlier group
        let transform = HoughTransform(dataWidth: bounds.width,
                                       dataHeight: bounds.height,
                                       inputData: pixels,
                                       maxPixelDistance: maxPixelDistance)

        // we want all the lines, all of them.
        self.lines = transform.lines(minCount: 1)
        _ = self.houghLineHistogram
    }

    public static func == (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name == rhs.name && lhs.frameIndex == rhs.frameIndex
    }
    
    public static func < (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name < rhs.name
    }
    
    nonisolated public var description: String {
        "outlier group \(frameIndex).\(name) size \(size) "
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(frameIndex)
    }
    
    public func shouldPaint(_ shouldPaint: PaintReason) async {
        //Log.d("\(self) should paint \(shouldPaint)")
        self.shouldPaint = shouldPaint

        // XXX update frame that it's different 
        self.frame?.markAsChanged()
    }

    private var cachedTestImage: CGImage? 
    
    // outputs an image the same size as this outlier's bounding box,
    // coloring the outlier pixels red if will paint, green if not
    public func testImage() -> CGImage? {

        // return cached version if present
        if let ret = cachedTestImage { return ret }
        
        let bytesPerPixel = 64/8
        
        var imageData = Data(count: self.bounds.width*self.bounds.height*bytesPerPixel)
        for x in 0 ..< self.bounds.width {
            for y in 0 ..< self.bounds.height {
                let pixelIndex = y*self.bounds.width + x
                var pixel = Pixel()
                if self.pixels[pixelIndex] != 0 {
                    // the real color is set in the view layer 
                    pixel.red = 0xFFFF
                    pixel.green = 0xFFFF
                    pixel.blue = 0xFFFF
                    pixel.alpha = 0xFFFF

                    var nextValue = pixel.value
                    
                    let offset = (Int(y) * bytesPerPixel*self.bounds.width) + (Int(x) * bytesPerPixel)
                    
                    imageData.replaceSubrange(offset ..< offset+bytesPerPixel,
                                               with: &nextValue,
                                               count: bytesPerPixel)

                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let dataProvider = CGDataProvider(data: imageData as CFData) {
            let ret = CGImage(width: self.bounds.width,
                              height: self.bounds.height,
                              bitsPerComponent: 16,
                              bitsPerPixel: bytesPerPixel*8,
                              bytesPerRow: self.bounds.width*bytesPerPixel,
                              space: colorSpace,
                              bitmapInfo: bitmapInfo,
                              provider: dataProvider,
                              decode: nil,
                              shouldInterpolate: false,
                              intent: .defaultIntent)
            cachedTestImage = ret
            return ret
        } else {
            return nil
        }
    }
    
    // how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
    func pixelOverlap(with group2: OutlierGroup) async -> Double // 1 means total overlap, 0 means none
    {
        let group1 = self
        // throw out non-overlapping frames, do any slip through?
        if group1.bounds.min.x > group2.bounds.max.x || group1.bounds.min.y > group2.bounds.max.y { return 0 }
        if group2.bounds.min.x > group1.bounds.max.x || group2.bounds.min.y > group1.bounds.max.y { return 0 }

        var minX = group1.bounds.min.x
        var minY = group1.bounds.min.y
        var maxX = group1.bounds.max.x
        var maxY = group1.bounds.max.y
        
        if group2.bounds.min.x > minX { minX = group2.bounds.min.x }
        if group2.bounds.min.y > minY { minY = group2.bounds.min.y }
        
        if group2.bounds.max.x < maxX { maxX = group2.bounds.max.x }
        if group2.bounds.max.y < maxY { maxY = group2.bounds.max.y }
        
        // XXX could search a smaller space probably

        var overlapPixelAmount = 0;
        
        for x in minX ... maxX {
            for y in minY ... maxY {
                let outlier1Index = (y - group1.bounds.min.y) * group1.bounds.width + (x - group1.bounds.min.x)
                let outlier2Index = (y - group2.bounds.min.y) * group2.bounds.width + (x - group2.bounds.min.x)
                if outlier1Index > 0,
                   outlier1Index < group1.pixels.count,
                   group1.pixels[outlier1Index] != 0,
                   outlier2Index > 0,
                   outlier2Index < group2.pixels.count,
                   group2.pixels[outlier2Index] != 0
                {
                    overlapPixelAmount += 1
                }
            }
        }

        if overlapPixelAmount > 0 {
            let avgGroupSize = (Double(group1.size) + Double(group2.size)) / 2
            return Double(overlapPixelAmount)/avgGroupSize
        }
        
        return 0
    }

    // decision code moved from extension because of swift bug:
    // https://forums.swift.org/t/actor-isolation-delegates-in-extensions/60571/6

    // ordered by the list of features below
    var decisionTreeValues: [Double] {
        get async {
            var ret: [Double] = []
            for type in OutlierGroup.Feature.allCases {
                ret.append(await self.decisionTreeValue(for: type))
            }
            return ret
        } 
    }

    // the ordering of the list of values above
    static var decisionTreeValueTypes: [OutlierGroup.Feature] {
        var ret: [OutlierGroup.Feature] = []
        for type in OutlierGroup.Feature.allCases {
            ret.append(type)
        }
        return ret
    }

     public var decisionTreeGroupValues: OutlierFeatureData {
        get async {
            var rawValues = OutlierFeatureData.rawValues()
            for type in OutlierGroup.Feature.allCases {
                let value = await self.decisionTreeValue(for: type)
                rawValues[type.sortOrder] = value
                //Log.d("frame \(frameIndex) type \(type) value \(value)")
            }
            return OutlierFeatureData(rawValues)
        } 
    }
    
    // we derive a Double value from each of these
    // all switches on this enum are in this file
    // add a new case, handle all switches here, and the
    // decision tree generator will use it after recompile
    // all existing outlier value files will need to be regenerated to include itx
    public enum Feature: String,
                         CaseIterable,
                         Hashable,
                         Codable,
                         Comparable
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
        case avgCountOfFirst10HoughLines
        case maxThetaDiffOfFirst10HoughLines
        case maxRhoDiffOfFirst10HoughLines
        case avgCountOfAllHoughLines
        case maxThetaDiffOfAllHoughLines
        case maxRhoDiffOfAllHoughLines
        case numberOfNearbyOutliersInSameFrame
        case adjecentFrameNeighboringOutliersBestTheta
        case histogramStreakDetection
        case longerHistogramStreakDetection
        case maxHoughTransformCount
        case maxHoughTheta
        case neighboringInterFrameOutlierThetaScore
        case maxOverlap
        case maxOverlapTimesThetaHisto
        
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
            for type in OutlierGroup.Feature.allCases {
                ret += "\(type.rawValue)\n"
            }

            return ret
        }
        
        public var needsAsync: Bool {
            switch self {
            case .numberOfNearbyOutliersInSameFrame:
                return true
            case .adjecentFrameNeighboringOutliersBestTheta:
                return true
            case .histogramStreakDetection:
                return true
            case .longerHistogramStreakDetection:
                return true
            case .neighboringInterFrameOutlierThetaScore:
                return true
            case .maxOverlap:
                return true
            case .maxOverlapTimesThetaHisto:
                return true
            default:
                return false
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
            case .avgCountOfFirst10HoughLines:
                return 16
            case .maxThetaDiffOfFirst10HoughLines:
                return 17
            case .maxRhoDiffOfFirst10HoughLines: // scored better without this
                return 18
            case .avgCountOfAllHoughLines:
                return 19
            case .maxThetaDiffOfAllHoughLines:
                return 20
            case .maxRhoDiffOfAllHoughLines:
                return 21
            case .numberOfNearbyOutliersInSameFrame:
                return 22
            case .adjecentFrameNeighboringOutliersBestTheta:
                return 23
            case .histogramStreakDetection:
                return 24
            case .longerHistogramStreakDetection:
                return 25
            case .maxHoughTransformCount:
                return 26
            case .maxHoughTheta:
                return 27
            case .neighboringInterFrameOutlierThetaScore:
                return 28
            case .maxOverlap:
                return 29
            case .maxOverlapTimesThetaHisto:
                return 30
            }
        }

        public static func ==(lhs: Feature, rhs: Feature) -> Bool {
            return lhs.sortOrder == rhs.sortOrder
        }

        public static func <(lhs: Feature, rhs: Feature) -> Bool {
            return lhs.sortOrder < rhs.sortOrder
        }        
    }

    fileprivate func nonAsyncDecisionTreeValue(for type: Feature) -> Double {
        let height = IMAGE_HEIGHT!
        let width = IMAGE_WIDTH!
        switch type {
            // attempt to normalize all pixel size related values
            // divide by width and/or hight
        case .size:
            return Double(self.size)/(height*width)
        case .width:
            return Double(self.bounds.width)/width
        case .height:
            return Double(self.bounds.height)/height
        case .centerX:
            return Double(self.bounds.center.x)/width
        case .minX:
            return Double(self.bounds.min.x)/width
        case .maxX:
            return Double(self.bounds.max.x)/width
        case .minY:
            return Double(self.bounds.min.y)/height
        case .maxY:
            return Double(self.bounds.max.y)/height
        case .centerY:
            return Double(self.bounds.center.y)/height
        case .hypotenuse:
            return Double(self.bounds.hypotenuse)/(height*width)
        case .aspectRatio:
            return Double(self.bounds.width) / Double(self.bounds.height)
        case .fillAmount:
            return Double(size)/(Double(self.bounds.width)*Double(self.bounds.height))
        case .surfaceAreaRatio:
            return self.surfaceAreaToSizeRatio
        case .averagebrightness:
            return Double(self.brightness)
        case .medianBrightness:            
            return self.medianBrightness
        case .maxBrightness:    
            return self.maxBrightness
        case .avgCountOfFirst10HoughLines:
            return self.avgCountOfFirst10HoughLines
        case .maxThetaDiffOfFirst10HoughLines:
            return self.maxThetaDiffOfFirst10HoughLines
        case .maxRhoDiffOfFirst10HoughLines:
            return self.maxRhoDiffOfFirst10HoughLines
        case .avgCountOfAllHoughLines:
            return self.avgCountOfAllHoughLines
        case .maxThetaDiffOfAllHoughLines:
            return self.maxThetaDiffOfAllHoughLines
        case .maxRhoDiffOfAllHoughLines:
            return self.maxRhoDiffOfAllHoughLines
        case .maxHoughTransformCount:
            return self.maxHoughTransformCount
        case .maxHoughTheta:
            return self.maxHoughTheta
        default:
            fatalError("called with bad value \(type) @ index \(frameIndex)")
        }
    }

    fileprivate var featureValueCache: [Feature: Double] = [:]

    public func clearFeatureValueCache() { featureValueCache = [:] }
    
    public func decisionTreeValue(for type: Feature) async -> Double {
        //Log.d("group \(name) @ frame \(frameIndex) decisionTreeValue(for: \(type))")

        if let value = featureValueCache[type] { return value }
        
        switch type {
        case .numberOfNearbyOutliersInSameFrame:
            let ret = await self.numberOfNearbyOutliersInSameFrame
            featureValueCache[type] = ret
            return ret
        case .adjecentFrameNeighboringOutliersBestTheta:
            let ret = await self.adjecentFrameNeighboringOutliersBestTheta
            featureValueCache[type] = ret
            return ret
        case .histogramStreakDetection:
            let ret = await self.histogramStreakDetection
            featureValueCache[type] = ret
            return ret
        case .longerHistogramStreakDetection:
            let ret = await self.longerHistogramStreakDetection
            featureValueCache[type] = ret
            return ret
        case .neighboringInterFrameOutlierThetaScore:
            let ret = await self.neighboringInterFrameOutlierThetaScore
            featureValueCache[type] = ret
            return ret
        case .maxOverlap:
            let ret = await self.maxOverlap
            featureValueCache[type] = ret
            return ret
        case .maxOverlapTimesThetaHisto:
            let ret = await self.maxOverlapTimesThetaHisto
            featureValueCache[type] = ret
            return ret
        default:
            let ret = self.nonAsyncDecisionTreeValue(for: type)
            featureValueCache[type] = ret
            return ret
        }
    }

    fileprivate var maxBrightness: Double {
        var max: UInt32 = 0
        for pixel in pixels {
            if pixel > max { max = pixel }
        }
        return Double(max)
    }
    
    fileprivate var medianBrightness: Double {
        var values: [UInt32] = []
        for pixel in pixels {
            if pixel > 0 {
                values.append(pixel)
            }
        }
        // XXX all zero pixels :(
        return Double(values.sorted()[values.count/2]) // SIGABRT HERE :(
    }

    fileprivate var numberOfNearbyOutliersInSameFrame: Double {
        get async {
            if let frame = frame,
               let nearbyGroups = frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                       of: self.bounds)
            {
                return Double(nearbyGroups.count)
            } else {
                fatalError("Died on frame \(frameIndex)")
            }
        }
    }

    fileprivate var _houghLineHistogram: HoughLineHistogram?
    
    // use these to compare outliers in same and different frames
    var houghLineHistogram: HoughLineHistogram {
        // use cached copy if possible
        if let _houghLineHistogram = _houghLineHistogram { return _houghLineHistogram }
        
        let lines = self.lines                            // try to copy
        let ret = HoughLineHistogram(withDegreeIncrement: 5, // XXX hardcoded 5
                                     lines: lines,
                                     andGroupSize: self.size)
        // cache it for later
        _houghLineHistogram = ret
        return ret
    }

    fileprivate var maxHoughTheta: Double {
        if let firstLine = self.firstLine {
            return Double(firstLine.theta)
        }
        return 0
    }
        
    fileprivate var maxHoughTransformCount: Double {
        if let firstLine = self.firstLine {
            return Double(firstLine.count)/Double(self.size)
        }
        return 0
    }

    fileprivate var maxNearbyGroupDistance: Double {
        800*7000/IMAGE_WIDTH! // XXX hardcoded constant
    }

    // returns 1 if they are the same
    // returns 0 if they are 180 degrees apart
    fileprivate func thetaScore(between theta1: Double, and theta2: Double) -> Double {

        var theta1Opposite = theta1 + 180
        if theta1Opposite > 360 { theta1Opposite -= 360 }

        var oppositeDifference = theta1Opposite - theta2

        if oppositeDifference <   0 { oppositeDifference += 360 }
        if oppositeDifference > 360 { oppositeDifference -= 360 }

        return oppositeDifference / 180.0
    }
    
    // tries to find a streak with hough line histograms
    fileprivate var histogramStreakDetection: Double {
        get async {
            if let frame = frame {
                var bestScore = 0.0
                let selfHisto = self.houghLineHistogram

                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                    of: self.bounds)
                {
                    for group in nearbyGroups {
                        let score = self.thetaHistoCenterLineScore(with: group,
                                                                   selfHisto: selfHisto)
                        bestScore = max(score, bestScore)
                    }
                }
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                of: self.bounds)
                {
                    for group in nearbyGroups {
                        let score = self.thetaHistoCenterLineScore(with: group,
                                                                   selfHisto: selfHisto)
                        bestScore = max(score, bestScore)
                    }
                }
                return bestScore
            } else {
                fatalError("NO FRAME for histogramStreakDetection @ index \(frameIndex)")
            }
        }
    }

    // a score based upon a comparsion of the theta histograms of the this and another group,
    // as well as how well the theta of the other group corresponds to the center line theta between them
    fileprivate func thetaHistoCenterLineScore(with group: OutlierGroup,
                                               selfHisto: HoughLineHistogram? = nil) -> Double
    {
        var histo = selfHisto
        if histo == nil { histo = self.houghLineHistogram }
        let centerLineTheta = self.bounds.centerTheta(with: group.bounds)
        let otherHisto = group.houghLineHistogram
        let histoScore = otherHisto.matchScore(with: histo!)
        let thetaScore = thetaScore(between: centerLineTheta, and: otherHisto.maxTheta)
        return histoScore*thetaScore
    }
    
    // tries to find a streak with hough line histograms
    // make this recursive to go back 3 frames in each direction
    fileprivate var longerHistogramStreakDetection: Double {
        get async {
            let numberOfFrames = 10 // how far in each direction to go
            let forwardScore = await self.streakScore(in: .forwards, numberOfFramesLeft: numberOfFrames)
            let backwardScore = await self.streakScore(in: .backwards, numberOfFramesLeft: numberOfFrames)
            return forwardScore + backwardScore
        }
    }

    fileprivate var maxOverlap: Double {
        get async {
            var maxOverlap = 0.0
            if let frame = frame {
                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                          of: self.bounds)
                {
                    for group in nearbyGroups {
                        maxOverlap = max(await self.pixelOverlap(with: group), maxOverlap)
                    }
                }
                
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                      of: self.bounds)
                {
                    for group in nearbyGroups {
                        maxOverlap = max(await self.pixelOverlap(with: group), maxOverlap)
                    }
                }
                
            }
            return maxOverlap
        }
    }

    fileprivate var maxOverlapTimesThetaHisto: Double {
        get async {
            var maxOverlap = 0.0
            if let frame = frame {
                let selfHisto = self.houghLineHistogram

                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                    of: self.bounds)
                {
                    for group in nearbyGroups {
                        let otherHisto = group.houghLineHistogram
                        let histoScore = otherHisto.matchScore(with: selfHisto)
                        let overlap = await self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histoScore, maxOverlap)
                    }
                }
                
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                of: self.bounds)
                {
                    for group in nearbyGroups {
                        let otherHisto = group.houghLineHistogram
                        let histoScore = otherHisto.matchScore(with: selfHisto)
                        let overlap = await self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histoScore, maxOverlap)
                    }
                }
            }            
            return maxOverlap
        }
    }
    
    fileprivate var neighboringInterFrameOutlierThetaScore: Double {
        // XXX doesn't use related frames 
        get async {
            if let frame = frame,
               let nearbyGroups = frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                             of: self.bounds)
            {
                let selfHisto = self.houghLineHistogram
                var ret = 0.0
                var count = 0
                for group in nearbyGroups {
                    if group.name == self.name { continue }
                    let centerLineTheta = self.bounds.centerTheta(with: group.bounds)
                    let otherHisto = group.houghLineHistogram
                    let otherThetaScore = thetaScore(between: centerLineTheta, and: otherHisto.maxTheta)
                    let selfThetaScore = thetaScore(between: centerLineTheta, and: selfHisto.maxTheta)
                    let histoScore = otherHisto.matchScore(with: selfHisto)

                    // modify this score by how close the theta of
                    // the line between the outlier groups center points
                    // is to the the theta of both of them
                    ret += selfThetaScore * otherThetaScore * histoScore
                    count += 1
                }
                if count > 0 { ret /= Double(count) }
                return ret
            }
            return 0
        }
    }
    
    // tries to find the closest theta on any nearby outliers on adjecent frames
    fileprivate var adjecentFrameNeighboringOutliersBestTheta: Double {
        /*
         instead of finding the closest theta, maybe use a probability distribution of thetas
         weighted by line count

         use this across all nearby outlier groups in adjecent frames, and notice if there
         is only one good (or decent) match, or a slew of bad matches
         */
        get async {
            if let frame = frame {
                let thisTheta = self.firstLine?.theta ?? 180
                var smallestDifference: Double = 360
                if let previousFrame = frame.previousFrame,
                   let nearbyGroups =
                     previousFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                  of: self.bounds)
                {

                    for group in nearbyGroups {
                        if let firstLine = group.firstLine {
                            let difference = Double(abs(thisTheta - firstLine.theta))
                            if difference < smallestDifference {
                                smallestDifference = difference
                            }
                        }
                    }
                }

                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                of: self.bounds)
                {
                    for group in nearbyGroups {
                        if let firstLine = group.firstLine {
                            let difference = Double(abs(thisTheta - firstLine.theta))
                            if difference < smallestDifference {
                                smallestDifference = difference
                            }
                        }
                    }
                }
                
                return smallestDifference
            } else {
                fatalError("NO FRAME @ index \(frameIndex)")
            }
        }
    }

    fileprivate var maxThetaDiffOfFirst10HoughLines: Double {
        var maxDiff = 0.0
        let firstTheta = self.lines[0].theta
        var max = 10;
        if self.lines.count < max { max = self.lines.count }
        for i in 0..<max {
            let thisTheta = self.lines[i].theta
            let thisDiff = abs(thisTheta - firstTheta)
            if thisDiff > maxDiff { maxDiff = thisDiff }
        }
        return maxDiff
    }
    
    fileprivate var maxRhoDiffOfFirst10HoughLines: Double {
        var maxDiff = 0.0
        let firstRho = self.lines[0].rho
        var max = 10;
        if self.lines.count < max { max = self.lines.count }
        for i in 0..<max {
            let thisRho = self.lines[i].rho
            let thisDiff = abs(thisRho - firstRho)
            if thisDiff > maxDiff { maxDiff = thisDiff }
        }
        return maxDiff
    }
    
    fileprivate var avgCountOfFirst10HoughLines: Double {
        var sum = 0.0
        var divisor = 0.0
        var max = 10;
        if self.lines.count < max { max = self.lines.count }
        for i in 0..<max {
            sum += Double(self.lines[i].count)/Double(self.size)
            divisor += 1
        }
        return sum/divisor
    }

    fileprivate var maxThetaDiffOfAllHoughLines: Double {
        var maxDiff = 0.0
        let firstTheta = self.lines[0].theta
        for i in 1..<self.lines.count {
            let thisTheta = self.lines[i].theta
            let thisDiff = abs(thisTheta - firstTheta)
            if thisDiff > maxDiff { maxDiff = thisDiff }
        }
        return maxDiff
    }
    
    fileprivate var maxRhoDiffOfAllHoughLines: Double {
        var maxDiff = 0.0
        let firstRho = self.lines[0].rho
        for i in 1..<self.lines.count {
            let thisRho = self.lines[i].rho
            let thisDiff = abs(thisRho - firstRho)
            if thisDiff > maxDiff { maxDiff = thisDiff }
        }
        return maxDiff
    }
    
    fileprivate var avgCountOfAllHoughLines: Double {
        var sum = 0.0
        var divisor = 0.0
        for i in 0..<self.lines.count {
            sum += Double(self.lines[i].count)/Double(self.size)
            divisor += 1
        }
        return sum/divisor
    }

    /*
    func logDecisionTreeValues() {
        var message = "decision tree values for \(self.name): "
        for type in /*OutlierGroup.*/Feature.allCases {
            message += "\(type) = \(self.decisionTreeValue(for: type)) " 
        }
        Log.d(message)
        }*/

    

        fileprivate func streakScore(in direction: StreakDirection,
                     numberOfFramesLeft: Int,
                     existingValue: Double = 0) async -> Double
    {
        let selfHisto = self.houghLineHistogram
        var bestScore = 0.0
        var bestGroup: OutlierGroup?
        
        if let frame = self.frame,
           let otherFrame = direction == .forwards ? frame.nextFrame : frame.previousFrame,
           let nearbyGroups = otherFrame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                         of: self.bounds)
        {
            for nearbyGroup in nearbyGroups {
                let score = self.thetaHistoCenterLineScore(with: nearbyGroup,
                                                           selfHisto: selfHisto)
                bestScore = max(score, bestScore)
                if score == bestScore {
                    bestGroup = nearbyGroup
                }
            }
        }

        let score = existingValue + bestScore
        
        if numberOfFramesLeft != 0,
           let bestGroup = bestGroup
        {
            return await bestGroup.streakScore(in: direction,
                                           numberOfFramesLeft: numberOfFramesLeft - 1,
                                           existingValue: score)
        } else {
            return score
        }
    }

    public var persistentDataSizeBytes: Int {

        var size = 0

        //size: UInt           (64 bits)
        size += 8

        //bounds: BoundingBox  (four 64 bit Ints)
        size += 8 * 4

        //brightness: UInt     (64 bits)
        size += 8

        //number_lines:        (64 bits)
        size += 8

        //lines: [Line]        [three 64 bit values]
        size += lines.count * 8 * 3

        //number_pixels        (64 bits)
        size += 8
        
        //pixels: [UInt32]
        size += pixels.count * 4
        
        //maxPixelDistance: UInt16
        size += 2
        
        //surfaceAreaToSizeRatio: Double (64 bits)
        size += 8

        return size
    }

    public init(withName name: String,
                frameIndex: Int,
                with persitentData: Data) {
        var index: Int = 0

        self.name = name
        self.frameIndex = frameIndex
        
        let sizeData = persitentData.subdata(in: index..<index+8)
        self.size = sizeData.withUnsafeBytes { $0.load(as: UInt.self).bigEndian }
        index += 8

        //Log.d("\(self.name) read size \(self.size)")
        
        let bbMinXData = persitentData.subdata(in: index..<index+8)
        let bbMinX = bbMinXData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bbMinYData = persitentData.subdata(in: index..<index+8)
        let bbMinY = bbMinYData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bbMaxXData = persitentData.subdata(in: index..<index+8)
        let bbMaxX = bbMaxXData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bbMaxYData = persitentData.subdata(in: index..<index+8)
        let bbMaxY = bbMaxYData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        self.bounds = BoundingBox(min: Coord(x: bbMinX, y: bbMinY),
                               max: Coord(x: bbMaxX, y: bbMaxY))

        let brightnessData = persitentData.subdata(in: index..<index+8)
        self.brightness = brightnessData.withUnsafeBytes { $0.load(as: UInt.self).bigEndian }
        index += 8

        let linesCountData = persitentData.subdata(in: index..<index+8)
        let linesCount = linesCountData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        //Log.d("linesCount \(linesCount) index \(index) persitentData.count \(persitentData.count)")
        
        var _lines: [Line] = []
        
        for _ in 0..<linesCount {
            let thetaData = persitentData.subdata(in: index..<index+8)
            let theta = thetaData.withUnsafeBytes { $0.load(as: Double.self) }
            index += 8

            let rhoData = persitentData.subdata(in: index..<index+8)
            let rho = rhoData.withUnsafeBytes { $0.load(as: Double.self) }
            index += 8
            
            let countData = persitentData.subdata(in: index..<index+8)
            let count = countData.withUnsafeBytes { $0.load(as: Int.self) }
            index += 8
            
            _lines.append(Line(theta: theta, rho: rho, count: count))
        }
        self.lines = _lines

        let pixelsCountData = persitentData.subdata(in: index..<index+8)
        let pixelsCount = pixelsCountData.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        var pixels: [UInt32] = []

        //Log.d("pixelsCount \(pixelsCount) index \(index) persitentData.count \(persitentData.count)")
        
        for _ in 0..<pixelsCount {
            let pixelData = persitentData.subdata(in: index..<index+4)
            index += 4
            let pixel = pixelData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            pixels.append(pixel)
        }
        self.pixels = pixels
        
        let mpdd = persitentData.subdata(in: index..<index+2)
        self.maxPixelDistance = mpdd.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        index += 2

        let satsrd = persitentData.subdata(in: index..<index+8)
        self.surfaceAreaToSizeRatio = satsrd.withUnsafeBytes { $0.load(as: Double.self) }
        index += 8
        
        // surfaceAreaToSizeRatio

        _ = self.houghLineHistogram
    }
    
    public var persistentData: Data {

        let size = self.persistentDataSizeBytes
        var data = Data(repeating: 0, count: size)

        //Log.d("\(self.name) creating persistent data of size \(size)")

        var index: Int = 0

        let sizeData = withUnsafeBytes(of: self.size.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: sizeData)
        index += 8
        
        //Log.d("\(self.name) size \(self.size)")

        let bbMinX = self.bounds.min.x
        let bbMinXData = withUnsafeBytes(of: bbMinX.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bbMinXData)
        index += 8
        
        let bbMinY = self.bounds.min.y
        let bbMinYData = withUnsafeBytes(of: bbMinY.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bbMinYData)
        index += 8
        
        let bbMaxX = self.bounds.max.x
        let bbMaxXData = withUnsafeBytes(of: bbMaxX.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bbMaxXData)
        index += 8

        let bbMaxY = self.bounds.max.y
        let bbMaxYData = withUnsafeBytes(of: bbMaxY.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bbMaxYData)
        index += 8

        let brightnessData = withUnsafeBytes(of: self.brightness.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: brightnessData)
        index += 8

        let numLines = self.lines.count
        let numLinesData = withUnsafeBytes(of: numLines.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: numLinesData)
        index += 8

        //Log.d("\(self.name) self.lines.count \(self.lines.count)")

        for line in self.lines {
            let thetaData = withUnsafeBytes(of: line.theta) { Data($0) }
            data.replaceSubrange(index..<index+8, with: thetaData)
            index += 8
            let rhoData = withUnsafeBytes(of: line.rho) { Data($0) }
            data.replaceSubrange(index..<index+8, with: rhoData)
            index += 8
            let countData = withUnsafeBytes(of: line.count.bigEndian) { Data($0) }
            data.replaceSubrange(index..<index+8, with: countData)
            index += 8
        }

        let numPixels = self.pixels.count
        
        //Log.d("\(self.name) self.pixels.count \(self.pixels.count)")

        let numPixelsData = withUnsafeBytes(of: numPixels.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: numPixelsData)
        index += 8

        for i in 0..<numPixels {
            let pixelData = withUnsafeBytes(of: self.pixels[i].bigEndian) { Data($0) }
            data.replaceSubrange(index..<index+4, with: pixelData)
            index += 4
        }

        let mpdd = withUnsafeBytes(of: self.maxPixelDistance.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+2, with: mpdd)
        index += 2

        data.replaceSubrange(index..<index+8,
                             with: withUnsafeBytes(of: self.surfaceAreaToSizeRatio) { Data($0) })
        index += 8

        return data        
    }

    // the suffix on the custom binary file we save each outlier group into
    static let dataBinSuffix = "outlier-data.bin"

    // the suffix of the paint reason json sidecar file for each outlier group
    static let paintJsonSuffix = "paint.json"

    public func writeToFile(in dir: String) async throws {
        let filename = "\(dir)/\(self.name)-\(OutlierGroup.dataBinSuffix)"

        if fileManager.fileExists(atPath: filename) {
            // we don't modify this outlier data, so not point in persisting it again
            //Log.i("not overwriting already existing filename \(filename)")
        } else {
            fileManager.createFile(atPath: filename,
                                    contents: self.persistentData,
                                    attributes: nil)
        }
        if let shouldPaint = self.shouldPaint {
            // also write out a separate json file with paint reason
            // this can be easily changed later if desired without re-writing the whole binary file
            let filename = "\(dir)/\(self.name)-\(OutlierGroup.paintJsonSuffix)"

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")

            let jsonData = try encoder.encode(shouldPaint)
            if fileManager.fileExists(atPath: filename) {
                //Log.i("removing already existing paint reason \(filename)")
                try fileManager.removeItem(atPath: filename)
            } 
            //Log.i("creating \(filename)")                      
            fileManager.createFile(atPath: filename,
                                contents: jsonData,
                                attributes: nil)
        }
    }
}

public func ratioOfSurfaceAreaToSize(of pixels: [UInt32], width: Int, height: Int) -> Double {
    var size: Int = 0
    var surfaceArea: Int = 0
    for x in 0 ..< width {
        for y in 0 ..< height {
            let index = y * width + x

            if pixels[index] != 0 {
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
        }
    }
    return Double(surfaceArea)/Double(size)
}

fileprivate let fileManager = FileManager.default
