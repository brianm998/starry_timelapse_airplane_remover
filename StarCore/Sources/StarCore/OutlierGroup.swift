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
// XXX these suck, find a better way
public var IMAGE_WIDTH: Double?
public var IMAGE_HEIGHT: Double?

// used for both outlier groups and raw data
public protocol ClassifiableOutlierGroup {
    func decisionTreeValue(for type: OutlierGroup.Feature) -> Double 
}

// represents a single outler group in a frame
public class OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable,
                           ClassifiableOutlierGroup
{
    public let name: String
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public let lines: [Line]           // sorted lines from the hough transform of this outlier group

    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    public let pixels: [UInt16]        // indexed by y * bounds.width + x

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
         pixels: [UInt16],
         maxPixelDistance: UInt16) 
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
                                       inputData: pixels)

        // try a smaller line count, with fixed trimming code
        self.lines = transform.lines(maxCount: 60, minPixelValue: 1) 
        _ = self.houghLineHistogram
    }

    public init(name: String,
                size: UInt,
                brightness: UInt,      // average brightness
                bounds: BoundingBox,
                frameIndex: Int,
                pixels: [UInt16],
                maxPixelDistance: UInt16) 
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frameIndex = frameIndex
        self.pixels = pixels
        self.maxPixelDistance = maxPixelDistance
        self.surfaceAreaToSizeRatio = ratioOfSurfaceAreaToSize(of: pixels,
                                                               width: bounds.width,
                                                               height: bounds.height)
        // do a hough transform on just this outlier group
        let transform = HoughTransform(dataWidth: bounds.width,
                                       dataHeight: bounds.height,
                                       inputData: pixels)

        // try a smaller line count, with fixed trimming code
        self.lines = transform.lines(maxCount: 60, minPixelValue: 1) 
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
    func pixelOverlap(with group2: OutlierGroup) -> Double // 1 means total overlap, 0 means none
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

    // cached value
    private var _decisionTreeValues: [Double]?
    
    // ordered by the list of features below
    var decisionTreeValues: [Double] {
        get async {
            if let _decisionTreeValues = _decisionTreeValues {
                return _decisionTreeValues
            }
            var ret: [Double] = []
            for type in OutlierGroup.Feature.allCases {
                ret.append(self.decisionTreeValue(for: type))
            }
            _decisionTreeValues = ret
            return ret
        } 
    }

    // cached value
    private static var _decisionTreeValueTypes: [OutlierGroup.Feature]?
    
    // the ordering of the list of values above
    static var decisionTreeValueTypes: [OutlierGroup.Feature] {
        if let _decisionTreeValueTypes = _decisionTreeValueTypes {
            return _decisionTreeValueTypes
        }
        var ret: [OutlierGroup.Feature] = []
        for type in OutlierGroup.Feature.allCases {
            ret.append(type)
        }
        _decisionTreeValueTypes = ret
        return ret
    }

     public var decisionTreeGroupValues: OutlierFeatureData {
        get async {
            var rawValues = OutlierFeatureData.rawValues()
            for type in OutlierGroup.Feature.allCases {
                let value = self.decisionTreeValue(for: type)
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
        case pixelBorderAmount
        
        /*
         XXX add:
           - config stuff:
             - outlierMaxThreshold
             - minGroupSize
         
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
            case .pixelBorderAmount:
                return 31
            }
        }

        public static func ==(lhs: Feature, rhs: Feature) -> Bool {
            return lhs.sortOrder == rhs.sortOrder
        }

        public static func <(lhs: Feature, rhs: Feature) -> Bool {
            return lhs.sortOrder < rhs.sortOrder
        }        
    }

    fileprivate var featureValueCache: [Feature: Double] = [:]

    public func clearFeatureValueCache() { featureValueCache = [:] }
    
    public func decisionTreeValue(for type: Feature) -> Double {
        let height = IMAGE_HEIGHT!
        let width = IMAGE_WIDTH!

        if let value = featureValueCache[type] { return value }

        //let t0 = NSDate().timeIntervalSince1970

        var ret: Double = 0.0
        
        switch type {
        case .size:
            ret = Double(self.size)/(height*width)
        case .width:
            ret = Double(self.bounds.width)/width
        case .height:
            ret = Double(self.bounds.height)/height
        case .centerX:
            ret = Double(self.bounds.center.x)/width
        case .minX:
            ret = Double(self.bounds.min.x)/width
        case .maxX:
            ret = Double(self.bounds.max.x)/width
        case .minY:
            ret = Double(self.bounds.min.y)/height
        case .maxY:
            ret = Double(self.bounds.max.y)/height
        case .centerY:
            ret = Double(self.bounds.center.y)/height
        case .hypotenuse:
            ret = Double(self.bounds.hypotenuse)/(height*width)
        case .aspectRatio:
            ret = Double(self.bounds.width) / Double(self.bounds.height)
        case .fillAmount:
            ret = Double(size)/(Double(self.bounds.width)*Double(self.bounds.height))
        case .surfaceAreaRatio:
            ret = self.surfaceAreaToSizeRatio
        case .averagebrightness:
            ret = Double(self.brightness)
        case .medianBrightness:            
            ret = self.medianBrightness
        case .maxBrightness:    
            ret = self.maxBrightness
        case .avgCountOfFirst10HoughLines:
            ret = self.avgCountOfFirst10HoughLines
        case .maxThetaDiffOfFirst10HoughLines:
            ret = self.maxThetaDiffOfFirst10HoughLines
        case .maxRhoDiffOfFirst10HoughLines:
            ret = self.maxRhoDiffOfFirst10HoughLines
        case .avgCountOfAllHoughLines:
            ret = self.avgCountOfAllHoughLines
        case .maxThetaDiffOfAllHoughLines:
            ret = self.maxThetaDiffOfAllHoughLines
        case .maxRhoDiffOfAllHoughLines:
            ret = self.maxRhoDiffOfAllHoughLines
        case .maxHoughTransformCount:
            ret = self.maxHoughTransformCount
        case .maxHoughTheta:
            ret = self.maxHoughTheta
        case .numberOfNearbyOutliersInSameFrame:
            ret = self.numberOfNearbyOutliersInSameFrame
        case .adjecentFrameNeighboringOutliersBestTheta:
            ret = self.adjecentFrameNeighboringOutliersBestTheta
        case .histogramStreakDetection:
            ret = self.histogramStreakDetection
        case .longerHistogramStreakDetection:
            ret = self.longerHistogramStreakDetection
        case .neighboringInterFrameOutlierThetaScore:
            ret = self.neighboringInterFrameOutlierThetaScore
        case .maxOverlap:
            ret = self.maxOverlap
        case .maxOverlapTimesThetaHisto:
            ret = self.maxOverlapTimesThetaHisto
        case .pixelBorderAmount:
            ret = self.pixelBorderAmount
        }
        //let t1 = NSDate().timeIntervalSince1970
        //Log.v("group \(name) @ frame \(frameIndex) decisionTreeValue(for: \(type)) = \(ret) after \(t1-t0)s")

        featureValueCache[type] = ret
        return ret
    }

    fileprivate var maxBrightness: Double {
        var max: UInt16 = 0
        for pixel in pixels {
            if pixel > max { max = pixel }
        }
        return Double(max)
    }
    
    fileprivate var medianBrightness: Double {
        var values: [UInt16] = []
        for pixel in pixels {
            if pixel > 0 {
                values.append(pixel)
            }
        }
        // XXX all zero pixels :(
        return Double(values.sorted()[values.count/2]) // SIGABRT HERE :(
    }

    fileprivate var numberOfNearbyOutliersInSameFrame: Double {
        get {
            if let frame = frame,
               let nearbyGroups = frame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                       of: self)
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

    public static var maxNearbyGroupDistance: Double {
        IMAGE_WIDTH!/8 // XXX hardcoded constant
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
        get {
            if let frame = frame {
                var bestScore = 0.0
                let selfHisto = self.houghLineHistogram

                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                    of: self)
                {
                    for group in nearbyGroups {
                        let score = self.thetaHistoCenterLineScore(with: group,
                                                                   selfHisto: selfHisto)
                        bestScore = max(score, bestScore)
                    }
                }
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                of: self)
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
        // XXX this MOFO is slow :(
        get {
            let numberOfFrames = 2 // how far in each direction to go
            let forwardScore = self.streakScore(going: .forwards, numberOfFramesLeft: numberOfFrames)
            let backwardScore = self.streakScore(going: .backwards, numberOfFramesLeft: numberOfFrames)
            return forwardScore + backwardScore
        }
    }

    fileprivate var maxOverlap: Double {
        get {
            var maxOverlap = 0.0
            if let frame = frame {
                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                          of: self)
                {
                    for group in nearbyGroups {
                        maxOverlap = max(self.pixelOverlap(with: group), maxOverlap)
                    }
                }
                
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                      of: self)
                {
                    for group in nearbyGroups {
                        maxOverlap = max(self.pixelOverlap(with: group), maxOverlap)
                    }
                }
                
            }
            return maxOverlap
        }
    }

    fileprivate var maxOverlapTimesThetaHisto: Double {
        get {
            var maxOverlap = 0.0
            if let frame = frame {
                let selfHisto = self.houghLineHistogram

                if let previousFrame = frame.previousFrame,
                   let nearbyGroups = previousFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                    of: self)
                {
                    for group in nearbyGroups {
                        let otherHisto = group.houghLineHistogram
                        let histoScore = otherHisto.matchScore(with: selfHisto)
                        let overlap = self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histoScore, maxOverlap)
                    }
                }
                
                if let nextFrame = frame.nextFrame,
                   let nearbyGroups = nextFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                of: self)
                {
                    for group in nearbyGroups {
                        let otherHisto = group.houghLineHistogram
                        let histoScore = otherHisto.matchScore(with: selfHisto)
                        let overlap = self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histoScore, maxOverlap)
                    }
                }
            }            
            return maxOverlap
        }
    }

    // how many neighors does each of the pixels in this outlier group have?
    // higher numbers mean they are packed closer together
    // lower numbers mean they are more of a disparate cloud
    fileprivate var pixelBorderAmount: Double {
        var totalNeighbors: Double = 0.0
        var totalSize: Int = 0
        
        for x in 0 ..< self.bounds.width {
            for y in 0 ..< self.bounds.height {
                let pixelIndex = y*self.bounds.width + x
                if self.pixels[pixelIndex] != 0 {
                    totalSize += 1

                    var leftIndex = x - 1
                    var rightIndex = x + 1
                    var topIndex = y - 1
                    var bottomIndex = y + 1
                    if leftIndex < 0 { leftIndex = 0 }
                    if topIndex < 0 { topIndex = 0 }
                    if rightIndex >= self.bounds.width { rightIndex = self.bounds.width - 1 }
                    if bottomIndex >= self.bounds.height { bottomIndex = self.bounds.height - 1 }

                    for neighborX in leftIndex...rightIndex {
                        for neighborY in topIndex...bottomIndex {
                            if neighborX != x,
                               neighborY != y,
                               self.pixels[neighborY*self.bounds.width + neighborX] != 0
                            {
                                totalNeighbors += 1
                            }
                        }
                    }
                }
            }
        }
        return totalNeighbors/Double(totalSize)
    }
    
    fileprivate var neighboringInterFrameOutlierThetaScore: Double {
        // XXX doesn't use related frames 
        get {
            if let frame = frame,
               let nearbyGroups = frame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                             of: self)
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
        get {
            if let frame = frame {
                let thisTheta = self.firstLine?.theta ?? 180
                var smallestDifference: Double = 360
                if let previousFrame = frame.previousFrame,
                   let nearbyGroups =
                     previousFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                  of: self)
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
                   let nearbyGroups = nextFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                                of: self)
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
        if self.lines.count > 0 {
            let firstTheta = self.lines[0].theta
            var max = 10;
            if self.lines.count < max { max = self.lines.count }
            for i in 0..<max {
                let thisTheta = self.lines[i].theta
                let thisDiff = abs(thisTheta - firstTheta)
                if thisDiff > maxDiff { maxDiff = thisDiff }
            }
        }
        return maxDiff
    }
    
    fileprivate var maxRhoDiffOfFirst10HoughLines: Double {
        var maxDiff = 0.0
        if self.lines.count > 0 {
            let firstRho = self.lines[0].rho
            var max = 10;
            if self.lines.count < max { max = self.lines.count }
            for i in 0..<max {
                let thisRho = self.lines[i].rho
                let thisDiff = abs(thisRho - firstRho)
                if thisDiff > maxDiff { maxDiff = thisDiff }
            }
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
        if self.lines.count > 0 {
            let firstTheta = self.lines[0].theta
            for i in 1..<self.lines.count {
                let thisTheta = self.lines[i].theta
                let thisDiff = abs(thisTheta - firstTheta)
                if thisDiff > maxDiff { maxDiff = thisDiff }
            }
        }
        return maxDiff
    }
    
    fileprivate var maxRhoDiffOfAllHoughLines: Double {
        var maxDiff = 0.0
        if self.lines.count > 0 {
            let firstRho = self.lines[0].rho
            for i in 1..<self.lines.count {
                let thisRho = self.lines[i].rho
                let thisDiff = abs(thisRho - firstRho)
                if thisDiff > maxDiff { maxDiff = thisDiff }
            }
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

    // XXX this MOFO is slow :(
    fileprivate func streakScore(going direction: StreakDirection,
                                 numberOfFramesLeft: Int,
                                 existingValue: Double = 0) -> Double
    {
        let selfHisto = self.houghLineHistogram
        var bestScore = 0.0
        var bestGroup: OutlierGroup?
        
        if let frame = self.frame,
           let otherFrame = direction == .forwards ? frame.nextFrame : frame.previousFrame,
           let nearbyGroups = otherFrame.outlierGroups(within: OutlierGroup.maxNearbyGroupDistance,
                                                         of: self)
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
            return  bestGroup.streakScore(going: direction,
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
        
        //pixels: [UInt16]
        size += pixels.count * 2
        
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

        var pixels: [UInt16] = []

        //Log.d("pixelsCount \(pixelsCount) index \(index) persitentData.count \(persitentData.count)")
        
        for _ in 0..<pixelsCount {
            let pixelData = persitentData.subdata(in: index..<index+2)
            index += 2
            let pixel = pixelData.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
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

        Log.d("\(self.name) creating persistent data of size \(size)")

        var index: Int = 0

        let sizeData = withUnsafeBytes(of: self.size.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: sizeData)
        index += 8
        
        Log.d("\(self.name) size \(self.size)")

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
            data.replaceSubrange(index..<index+2, with: pixelData)
            index += 2
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

public func ratioOfSurfaceAreaToSize(of pixels: [UInt16], width: Int, height: Int) -> Double {
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
