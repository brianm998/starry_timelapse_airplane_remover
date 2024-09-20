/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// https://stackoverflow.com/questions/63018581/fastest-way-to-save-structs-ios-swift
// XXX look into ContiguousBytes

import Foundation
import KHTSwift
import logging
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
// XXX make this an actor, seen crashes with multiple threads accessing at once
public class OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable,
                           ClassifiableOutlierGroup
{
    public let id: UInt16              // unique across a frame, non zero
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public let lines: [Line]           // sorted lines from the hough transform of this outlier group

    // how far away from the most dominant line in this outlier group are
    // the pixels in it, on average?
    public let averageLineVariance: Double

    // what is the length of the assumed line? 
    public let lineLength: Double

    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    public let pixels: [UInt16]        // indexed by y * bounds.width + x

    // a set of the pixels in this outlier 
    public let pixelSet: Set<SortablePixel>
    
    public let surfaceAreaToSizeRatio: Double

    public var shouldPaintDidChange: ((OutlierGroup, PaintReason?) -> Void)?
    
    // after init, shouldPaint is usually set to a base value based upon different statistics 
    public var shouldPaint: PaintReason? { // should we paint this group, and why?
        didSet {
            //Log.d("shouldPaint did change callback \(shouldPaintDidChange)")
        }
    }
    
    public let frameIndex: Int

    // has to be optional so we can read OuterlierGroups as codable
    public var frame: FrameAirplaneRemover?

    public func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }
    
    // returns the best line, if any

    fileprivate var _line: Line?
    
    var line: Line? { 
        if let _line { return _line }
        _line = HoughLineFinder(pixels: self.pixels, bounds: self.bounds).line
        return _line
    }

    // a line with (0,0) origin calculated from the pixels in this group, if possible
    public var originZeroLine: Line? {
        if let line { return originZeroLine(from: line) }
        return nil
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
    
    public init(id: UInt16,
                size: UInt,
                brightness: UInt,      // average brightness
                bounds: BoundingBox,
                frameIndex: Int,
                pixels: [UInt16],
                pixelSet: Set<SortablePixel>,
                line: Line?)
    {
        self._line = line
        self.id = id
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frameIndex = frameIndex
        self.pixels = pixels
        self.pixelSet = pixelSet
        self.surfaceAreaToSizeRatio = ratioOfSurfaceAreaToSize(of: pixels,
                                                               width: bounds.width,
                                                               height: bounds.height)

        if let line {
            (self.averageLineVariance, self.lineLength) = 
              OutlierGroup.averageDistance(for: pixels,
                                           from: line,
                                           with: bounds)
            self.lines = [line]

        } else {
            self.averageLineVariance = 0xFFFFFFFF
            self.lineLength = 0
            self.lines = []
            
            // look for a line if we're not given one ?
            /*
            if let line = HoughLineFinder(pixels: self.pixels, bounds: self.bounds).line {
                (self.averageLineVariance, self.lineLength) = 
                  OutlierGroup.averageDistance(for: pixels,
                                               from: line,
                                               with: bounds)
                self.lines = [line]
            } else {
                self.averageLineVariance = 0xFFFFFFFF
                self.lineLength = 0
                self.lines = []
            }
             */
        }
        
        _ = self.houghLineHistogram
    }

    // calculate how far, on average, the pixels in this group are from the ideal
    // line that we have calculated for this group,
    // divided by the total length pixels in that line.
    // A really straight, narrow line will have a low value,
    // while a big cloud of fuzzy points should have a larger value.
    // XXX move this elsewhere
    public static func averageDistance(for pixels: [UInt16],
                                       from line: Line,
                                       with bounds: BoundingBox,
                                       frameIndex: Int? = nil) -> (Double, Double)
    {
        var distanceSum: Double = 0.0
        var numDistances: Double = 0.0
        let standardLine = line.standardLine

        var minX = bounds.width
        var minY = bounds.width
        var maxX = 0
        var maxY = 0

        for x in 0..<bounds.width {
            for y in 0..<bounds.height {
                // calculate how close each pixel is to this line
                if pixels[y*bounds.width+x] > 0 {
                    let distance = standardLine.distanceTo(x: x, y: y)

                    // don't use a small outlying pixel with large distance
                    // from the line for the maximum, this can create situations
                    // where the score is reduced (improved) by adding a small
                    // far away pixel that is out of line

                    if distance < 4 { // XXX another constant :(
                        if y < minY { minY = y }
                        if x < minX { minX = x }
                        if y > maxY { maxY = y }
                        if x > maxX { maxX = x }
                    }

                    distanceSum += distance
                    numDistances += 1
                }
            }
        }


        let xDiff = Double(maxX-minX)
        let yDiff = Double(maxY-minY)
        let totalLength = sqrt(xDiff*xDiff+yDiff*yDiff)
        let distance = distanceSum/numDistances

        //if let frameIndex {
            //Log.d("frame \(frameIndex) averageDistance \(distance) \(numDistances) totalLength \(totalLength)")
    //}
        
        return (distance, totalLength)
    }

    public static func == (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.id == rhs.id && lhs.frameIndex == rhs.frameIndex
    }
    
    public static func < (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.id < rhs.id
    }
    
    nonisolated public var description: String {
        "outlier group \(frameIndex):\(id) size \(size) "
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(frameIndex)
    }
    
    public func shouldPaint(_ shouldPaint: PaintReason) {
        //Log.d("\(self) should paint \(shouldPaint) self.frame \(self.frame)")
        self.shouldPaint = shouldPaint

        // XXX update frame that it's different 
        self.frame?.markAsChanged()

        if let shouldPaintDidChange {
            //Log.d("shouldPaint did change 1")
            Task { @MainActor in
                //Log.d("shouldPaint did change 2")
                shouldPaintDidChange(self, shouldPaint)
            }
        }
    }

    // a local cache of other nearby groups
    lazy public var nearbyGroups: [OutlierGroup]? = {
        // only run this only once, and only if needed, as it's not fast
        self.frame?.outlierGroups?.groups(nearby: self, within: 80) // XXX hardcoded constant
    }()
    
    private var cachedTestImage: CGImage? 

    // x,y origin at 0,0
    fileprivate func hasPixelAt(x: Int, y: Int) -> Bool {
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
    
    fileprivate func testPaintAt(x: Int, y: Int, pixel: Pixel, imageData: inout Data) -> Bool {
        
        let bytesPerPixel = 64/8
        
        if x >= self.bounds.width ||
           x < 0 ||
           y >= self.bounds.height ||
           y < 0
        {
            return false
        }
        
        var nextValue = pixel.value
        
        let offset = (Int(y) * bytesPerPixel*self.bounds.width) + (Int(x) * bytesPerPixel)

        imageData.replaceSubrange(offset ..< offset+bytesPerPixel,
                                  with: &nextValue,
                                  count: bytesPerPixel)
        return true
    }
    
    // outputs an image the same size as this outlier's bounding box,
    // coloring the outlier pixels red if will paint, green if not
    public func testImage() -> CGImage? {

        let bytesPerPixel = 64/8
        
        // return cached version if present
        if let ret = cachedTestImage { return ret }
        
        var imageData = Data(count: self.bounds.width*self.bounds.height*bytesPerPixel)

        let writeLine = false   // XXX this is nice to see for debugging, but slow
        
        // maybe write out the line
        if writeLine,
//           self.size > 150,
           let line = self.line
        {
            Log.d("have LINE \(line)")
            var pixel = Pixel()
            pixel.blue = 0xFFFF
//            pixel.green = 0xFFFF
//            pixel.red = 0xFFFF
            pixel.alpha = 0xFFFF
            
            let centralCoord = DoubleCoord(x: Double(self.bounds.width/2),
                                           y: Double(self.bounds.height/2))

            //Log.d("centralCoord \(centralCoord)")
            line.iterate(.forwards, from: centralCoord) { x, y, iterationDirection in
                testPaintAt(x: x, y: y, pixel: pixel, imageData: &imageData)
            }
            line.iterate(.backwards, from: centralCoord) { x, y, iterationDirection in
                testPaintAt(x: x, y: y, pixel: pixel, imageData: &imageData)
            }
        }
        

        
        for x in 0 ..< self.bounds.width {
            for y in 0 ..< self.bounds.height {
                let pixelIndex = y*self.bounds.width + x
                var pixel = Pixel()
                if self.pixels[pixelIndex] != 0 { // XXX use pixelSet
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
        if let _decisionTreeValues = _decisionTreeValues {
            return _decisionTreeValues
        }
        var ret: [Double] = []
        ret.append(Double(self.id))
        for type in OutlierGroup.Feature.allCases {
            //let t0 = NSDate().timeIntervalSince1970
            ret.append(self.decisionTreeValue(for: type))
            //let t1 = NSDate().timeIntervalSince1970
            //Log.i("frame \(frameIndex) group \(self) took \(t1-t0) seconds to calculate value for \(type)")
        }
        _decisionTreeValues = ret
        return ret
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
         var rawValues = OutlierFeatureData.rawValues()
         for type in OutlierGroup.Feature.allCases {
             let t0 = NSDate().timeIntervalSince1970
             let value = self.decisionTreeValue(for: type)
             let t1 = NSDate().timeIntervalSince1970
             Log.i("frame \(frameIndex) group \(self) took \(t1-t0) seconds to calculate value for \(type)")
             rawValues[type.sortOrder] = value
             //Log.d("frame \(frameIndex) type \(type) value \(value)")
         }
         return OutlierFeatureData(rawValues)
    }
    
    // we derive a Double value from each of these
    // all switches on this enum are in this file
    // add a new case, handle all switches here, and the
    // decision tree generator will use it after recompile
    // all existing outlier value files will need to be regenerated to include it
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
        case numberOfNearbyOutliersInSameFrame
        case maxHoughTransformCount
        case pixelBorderAmount
        case averageLineVariance
        case lineLength

        case nearbyDirectOverlapScore
        case boundingBoxOverlapScore
        case lineFillAmount

        /*
         XXX add:
           - A new feature that accounts for empty space along the line
             given a line for the outlier group, what percentage of the pixels
             along that line (withing a small distance) are filled in by the
             outlier group, and what ones are not?  Airplane lines have more
             pixels along the line, random other assortments do not.
         
           - now that we've gotten good lines out of the KHT, try rewriting the old streak
             detection logic to iterate on an outliers line outside of its bounding box.
             score can be how good a fit is found on either side.  Fit can be determined
             by a combination of size, brightness, and line similarity, 0-1 where 1 is identical.

           - add median line variance
             
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
            case .numberOfNearbyOutliersInSameFrame:
                return 16
            case .maxHoughTransformCount:
                return 17
            case .pixelBorderAmount:
                return 18
            case .averageLineVariance:
                return 19
            case .lineLength:
                return 20
            case .nearbyDirectOverlapScore:
                return 21
            case .boundingBoxOverlapScore:
                return 22
            case .lineFillAmount:
                return 23
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
        case .maxHoughTransformCount:
            ret = self.maxHoughTransformCount
        case .numberOfNearbyOutliersInSameFrame: // keep out
            ret = self.numberOfNearbyOutliersInSameFrame
        case .nearbyDirectOverlapScore:
            ret = self.nearbyDirectOverlapScore
        case .boundingBoxOverlapScore:
            ret = self.boundingBoxOverlapScore
        case .pixelBorderAmount: // keep out
            ret = self.pixelBorderAmount
        case .averageLineVariance:
            ret = self.averageLineVariance
        case .lineLength:
            ret = self.lineLength
        case .lineFillAmount:
            ret = self.lineFillAmount
        }
        //let t1 = NSDate().timeIntervalSince1970
        //Log.d("group \(id) @ frame \(frameIndex) decisionTreeValue(for: \(type)) = \(ret) after \(t1-t0)s")

        featureValueCache[type] = ret
        return ret
    }

    fileprivate var maxBrightness: Double {
        var max: UInt16 = 0
        for pixel in pixels {   // XXX use pixelSet
            if pixel > max { max = pixel }
        }
        return Double(max)
    }
    
    fileprivate var medianBrightness: Double {
        var values: [UInt16] = []
        for pixel in pixels {   // // XXX use pixelSet
            if pixel > 0 {
                values.append(pixel)
            }
        }
        // XXX all zero pixels :(
        if values.count == 0 { return 0 }
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

    fileprivate var maxHoughTransformCount: Double {
        if let line = self.line {
            return Double(line.votes)/Double(self.size)
        }
        return 0
    }

    public static var maxNearbyGroupDistance: Double {
        IMAGE_WIDTH!/8 // XXX hardcoded constant
    }

    // 0 if no pixels are found withing the bounding box in neighboring frames
    // 1 if all pixels withing the bounding box in neighboring frames are filled
    // airplane streaks typically do not overlap the same pixels on neighboring frames
    fileprivate var boundingBoxOverlapScore: Double {

        if bounds.max.y - bounds.min.y < 2 { return 0 }
        
        if let frame {
            var matchCount = 0
            var numberFrames = 0

            if let previousFrame = frame.previousFrame,
               let previousOutlierGroups = previousFrame.outlierGroups
            {
                let previousOutlierGroupsOutlierYAxisImageData = previousOutlierGroups.outlierYAxisImageData
                let previousOutlierGroupsOutlierImageData = previousOutlierGroups.outlierImageData
                numberFrames += 1
                for y in bounds.min.y...bounds.max.y {
                    if let yAxis = previousOutlierGroupsOutlierYAxisImageData,
                       yAxis[y] == 0 { continue }
                    
                    for x in bounds.min.x...bounds.max.x {
                        let index = y*Int(IMAGE_WIDTH!) + x
                        if previousOutlierGroupsOutlierImageData[index] != 0 {
                            // there is an outlier here
                            matchCount += 1
                        }
                    }
                }
            }
            if let nextFrame = frame.nextFrame,
               let nextOutlierGroups = nextFrame.outlierGroups
            {
                let nextOutlierGroupsOutlierYAxisImageData = nextOutlierGroups.outlierYAxisImageData
                let nextOutlierGroupsOutlierImageData = nextOutlierGroups.outlierImageData
                numberFrames += 1
                for y in bounds.min.y...bounds.max.y {
                    if let yAxis = nextOutlierGroupsOutlierYAxisImageData,
                       yAxis[y] == 0 { continue }
                    
                    for x in bounds.min.x...bounds.max.x {
                        let index = y*Int(IMAGE_WIDTH!) + x
                        if nextOutlierGroupsOutlierImageData[index] != 0 {
                            // there is an outlier here
                            matchCount += 1
                        }
                    }
                }
            }

            if numberFrames == 0 { return 0 }
            return Double(matchCount)/(Double(numberFrames)*Double(bounds.width*bounds.height))
        } else {
            fatalError("NO FRAME for boundingBoxOverlapScore @ index \(frameIndex)")
        }
    }
    
    // 1.0 if all pixels in this group overlap all pixels of outliers in all neighboring frames
    // 0 if none of the pixels overlap
    // airplane streaks typically do not overlap the same pixels on neighboring frames
    fileprivate var nearbyDirectOverlapScore: Double {
        if let frame {
            let pixelCount = self.pixelSet.count
            var matchCount = 0
            let previousFrame = frame.previousFrame 
            let nextFrame = frame.nextFrame

            for pixel in pixelSet {
                let index = pixel.y * Int(IMAGE_WIDTH!) + pixel.x
                if let previousFrame,
                   let previousOutlierGroups = previousFrame.outlierGroups,
                   previousOutlierGroups.outlierImageData[index] != 0
                {
                    matchCount += 1
                }

                if let nextFrame,
                   let nextOutlierGroups = nextFrame.outlierGroups,
                   nextOutlierGroups.outlierImageData[index] != 0
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
            fatalError("NO FRAME for nearbyDirectOverlapScore @ index \(frameIndex)")
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
    public var lineFillAmount: Double {
        if let line = self.originZeroLine {
            let borders = self.bounds.intersections(with: line.standardLine)
            if borders.count > 1 {
                var totalPixels = 0
                var linePixels = 0
                
                line.iterate(between: borders[0],
                             and: borders[1],
                             numberOfAdjecentPixels: 1)
                { x, y, iterationDirection in
                    totalPixels += 1
                    if self.hasPixelAt(x: x, y: y) {
                        linePixels += 1
                    }
                }
                return Double(linePixels)/Double(totalPixels)
            } else {
                return 0
            }
        } else {
            return 0
        }
    }
    
    // how many neighors does each of the pixels in this outlier group have?
    // higher numbers mean they are packed closer together
    // lower numbers mean they are more of a disparate cloud

    // XXX use pixelSet
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
    
    lazy var blob: Blob = {
        Blob(pixelSet, id: id, frameIndex: frameIndex)
    }()
}

// XXX use pixelSet
// and outliers.tiff
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
