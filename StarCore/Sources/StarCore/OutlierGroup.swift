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
import Combine

// these need to be setup at startup so the decision tree values are right
// XXX these suck, find a better way
nonisolated(unsafe) public var IMAGE_WIDTH: Double?
nonisolated(unsafe) public var IMAGE_HEIGHT: Double?

@MainActor
@Observable
public class OutlierPaintObserver {
    public init() { }
    
    public var shouldPaint: PaintReason?

    public func set(shouldPaint: PaintReason?) {
        self.shouldPaint = shouldPaint
    }
}

// used for both outlier groups and raw data
public protocol ClassifiableOutlierGroup {
    func decisionTreeValue(for type: OutlierGroupFeature) -> Double 
}

// represents a single outler group in a frame
public actor OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable
{
    nonisolated public let id: UInt16              // unique across a frame, non zero
    nonisolated public let size: UInt              // number of pixels in this outlier group
    nonisolated public let bounds: BoundingBox     // a bounding box on the image that contains this group
    nonisolated public let brightness: UInt        // the average amount per pixel of brightness over the limit 


    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    nonisolated public let pixels: [UInt16]        // indexed by y * bounds.width + x

    // a set of the pixels in this outlier 
    nonisolated public let pixelSet: Set<SortablePixel>
    
    nonisolated public let frameIndex: Int

    // lazy calculcated properties

    fileprivate var _line: Line? = nil
    fileprivate var lineScore: Double? = nil

    fileprivate var lineLoaded = false
    fileprivate var shouldLoadLine = true

    public func getLineScore() -> Double? { lineScore }
    
    public func set(line: HoughLineFinder.LineInfo) {
        _line = line.line
        lineScore = line.score
        lineLoaded = true
    }

    public var lineFinder: CombinedHoughLineFinder {
        get async {
          await CombinedHoughLineFinder(pixels: Array(self.pixelSet),
                                        bounds: self.bounds,
                                        medianIntensity: self.medianIntensity(),
                                        maxIntensity: self.maxIntensity(),
                                        frameIndex: self.frameIndex)
        }
    }
    
    public func line() async -> Line? {
        if shouldLoadLine {
            shouldLoadLine = false
            return await Task<Line?,Never>.detached {
                if let line = await self.lineFinder.line
                {
                    await self.set(line: line)
                    return line.line
                } else {
                    return nil
                }
            }.value
        } else {
            return _line
        }
    }

    fileprivate var _bunchCount: Int? = nil
    fileprivate var _medianBunchSize: Int? = nil
    fileprivate var _maxBunchSize: Int? = nil
    
    public func bunchCount() -> Int {
        if let _bunchCount { return _bunchCount }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _bunchCount!
    }
    
    public func medianBunchSize() -> Int {
        if let _medianBunchSize { return _medianBunchSize }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _medianBunchSize!
    }
    
    public func maxBunchSize() -> Int {
        if let _maxBunchSize { return _maxBunchSize }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _maxBunchSize!
    }
    
    // how far away from the most dominant line in this outlier group are
    // the pixels in it, on average?
    public func averageLineVariance() async -> Double {
        if let _averageLineVariance { return _averageLineVariance }
        await setLineProperties()
        return _averageLineVariance!
    }
    fileprivate var _averageLineVariance: Double? = nil

    // on median?
    public func medianLineVariance() async -> Double {
        if let _medianLineVariance { return _medianLineVariance }
        await setLineProperties()
        return _medianLineVariance!
    }
    fileprivate var _medianLineVariance: Double? = nil

    // assumes line has 0,0 origin
    public func averageDistanceAndLineLength(from line: Line) -> (Double, Double) {
        var minX = Int.max
        var minY = Int.max
        var maxX = 0
        var maxY = 0
        
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        for pixel in pixelSet {

            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            
            if distance < 4 { // XXX another constant :(
                if pixel.y < minY { minY = pixel.y }
                if pixel.x < minX { minX = pixel.x }
                if pixel.y > maxY { maxY = pixel.y }
                if pixel.x > maxX { maxX = pixel.x }
            }

            distanceSum += distance 
        }
        let xDiff = Double(maxX-minX)
        let yDiff = Double(maxY-minY)
        let totalLength = sqrt(xDiff*xDiff+yDiff*yDiff)
        
        return (distanceSum/Double(pixelSet.count), totalLength)
    }
    
    public func shouldPaint() -> PaintReason? { _shouldPaint }

    fileprivate var _shouldPaint: PaintReason?  // should we paint this group, and why?

    public var paintObserver: OutlierPaintObserver?

    public func set(paintObserver: OutlierPaintObserver) {
        self.paintObserver = paintObserver
    }
    
    public func shouldPaint(_ shouldPaint: PaintReason) async {
        //Log.d("\(self) should paint \(shouldPaint) self.frame \(self.frame)")
        self._shouldPaint = shouldPaint

        // XXX update frame that it's different 
        await self.frame?.markAsChanged()
        await paintObserver?.set(shouldPaint: shouldPaint)
    }

    // has to be optional so we can read OuterlierGroups as codable
    public var frame: FrameAirplaneRemover?

    public func set(frame: FrameAirplaneRemover) {
        self.frame = frame
    }
    
    // a line with (0,0) origin calculated from the pixels in this group, if possible
    public var originZeroLine: Line? {
        get async {
            if let line = await self.line() { return originZeroLine(from: line) }
            return nil
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
    
    public init(id: UInt16,
                size: UInt,
                brightness: UInt,      // average brightness
                bounds: BoundingBox,
                frameIndex: Int,
                pixels: [UInt16],
                pixelSet: Set<SortablePixel>)
    {
        self.id = id
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frameIndex = frameIndex
        self.pixels = pixels
        self.pixelSet = pixelSet
    }

    private func setLineProperties() async {
        if let line = await self.originZeroLine {
            (self._averageLineVariance, self._medianLineVariance, _) = 
              OutlierGroup.averageMedianMaxDistance(for: pixelSet,
                                                    from: line,
                                                    with: bounds)
        } else {
            self._averageLineVariance = 0xFFFFFFFF
            self._medianLineVariance = 0xFFFFFFFF
        }
    }

    public func featureData() async -> OutlierGroupFeatureData {
        var values = [Double](repeating: 0, count: OutlierGroupFeature.allCases.count)
        var features = [OutlierGroupFeature](repeating: .size, count: OutlierGroupFeature.allCases.count)
        for type in OutlierGroupFeature.allCases {
            features[type.sortOrder] = type
            values[type.sortOrder] = await decisionTreeValueAsync(for: type)
        }
        return OutlierGroupFeatureData(features: features, values: values)
    }
    
    fileprivate static func averageMedianMaxDistance(for pixelSet: Set<SortablePixel>,
                                                     from line: Line,
                                                     with bounds: BoundingBox)
      -> (Double, Double, Double)
    {
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        var distances:[Double] = []
        var max: Double = 0
        
        for pixel in pixelSet {
            // calculate how close each pixel is to this line

            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            distanceSum += distance
            distances.append(distance)
            if distance > max { max = distance }
        }

        distances.sort { $0 > $1 }
        if pixelSet.count == 0 {
            return (0, 0, 0)
        } else {
            let average = distanceSum/Double(pixelSet.count)
            let median = distances[distances.count/2]
            return (average, median, max)
        }
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
        hasher.combine(pixelSet.count)
    }
    
    public func asyncHash(into hasher: inout Hasher) {
        self.hash(into: &hasher)
        if let _shouldPaint {
            hasher.combine(_shouldPaint)
        }
    }

    // a local cache of other nearby groups - NO LONGER CACHED AFTER SWIFT 6 :( 
    public func nearbyGroups() async -> [OutlierGroup]? {
        // only run this only once, and only if needed, as it's not fast
        await self.frame?.outlierGroups?.groups(nearby: self, within: 80) // XXX hardcoded constant
    }
    
    private var cachedTestImage: CGImage? 

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
    public func testImage() async -> CGImage? {

        let bytesPerPixel = 64/8
        
        // return cached version if present
        if let ret = cachedTestImage { return ret }
        
        var imageData = Data(count: self.bounds.width*self.bounds.height*bytesPerPixel)

        let writeLine = false   // XXX this is nice to see for debugging, but slow
        
        // maybe write out the line
        if writeLine,
//           self.size > 150,
           let line = await self.line()
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
        

        for pixel in pixelSet {
            var pixelToWrite = Pixel()
            // the real color is set in the view layer 
            pixelToWrite.red = 0xFFFF
            pixelToWrite.green = 0xFFFF
            pixelToWrite.blue = 0xFFFF
            pixelToWrite.alpha = 0xFFFF

            var nextValue = pixelToWrite.value
            
            let offset = (Int(pixel.y-bounds.min.y) * bytesPerPixel*self.bounds.width) +
                         (Int(pixel.x-bounds.min.x) * bytesPerPixel)
            
            imageData.replaceSubrange(offset ..< offset+bytesPerPixel,
                                      with: &nextValue,
                                      count: bytesPerPixel)

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

    // ordered by the list of features below
    func decisionTreeValues() async -> [Double] {
        var ret: [Double] = []
        ret.append(Double(self.id))
        for type in OutlierGroupFeature.allCases {
            //let t0 = NSDate().timeIntervalSince1970
            ret.append(await self.decisionTreeValueAsync(for: type))
            //let t1 = NSDate().timeIntervalSince1970
            //Log.i("frame \(frameIndex) group \(self) took \(t1-t0) seconds to calculate value for \(type)")
        }
        return ret
    }

    // the ordering of the list of values above
    static var decisionTreeValueTypes: [OutlierGroupFeature] {
        OutlierGroupFeature.allCases 
    }

    public func decisionTreeGroupValues() async -> OutlierFeatureData {
         var rawValues = OutlierFeatureData.rawValues()
         for type in OutlierGroupFeature.allCases {
             let t0 = NSDate().timeIntervalSince1970
             let value = await self.decisionTreeValueAsync(for: type)
             let t1 = NSDate().timeIntervalSince1970
             Log.i("frame \(frameIndex) group \(self) took \(t1-t0) seconds to calculate value for \(type)")
             rawValues[type.sortOrder] = value
             //Log.d("frame \(frameIndex) type \(type) value \(value)")
         }
         return OutlierFeatureData(rawValues)
    }
    

    fileprivate var featureValueCache: [OutlierGroupFeature: Double] = [:]

    public func clearFeatureValueCache() { featureValueCache = [:] }

    public func decisionTreeValueAsync(for type: OutlierGroupFeature) async -> Double {
        if let value = featureValueCache[type] { return value }

        //let t0 = NSDate().timeIntervalSince1970

        let ret = await type.decisionTreeValue(of: self)
        //let t1 = NSDate().timeIntervalSince1970
        //Log.d("group \(id) @ frame \(frameIndex) decisionTreeValue(for: \(type)) = \(ret) after \(t1-t0)s")

        featureValueCache[type] = ret
        return ret
    }

    public static var maxNearbyGroupDistance: Double {
        IMAGE_WIDTH!/8 // XXX hardcoded constant
    }
    
    func blob() -> Blob {
        Blob(pixelSet, id: id, frameIndex: frameIndex)
    }

    public func medianIntensity() -> UInt16 {
        if pixelSet.count == 0 { return 0 }
        if let _medianIntensity { return _medianIntensity }
        let intensities = pixelSet.map { $0.intensity }
        if intensities.count == 0 {
            _medianIntensity = 0
            return 0
        }
        let ret = intensities.sorted()[intensities.count/2]
        _medianIntensity = ret
        return ret
    }

    public func maxIntensity() -> UInt16 {
        if pixelSet.count == 0 { return 0 }
        if let _maxIntensity { return _maxIntensity }
        var ret: UInt16 = 0
        for pixel in pixelSet {
            if pixel.intensity > ret { ret = pixel.intensity }
        }
        _maxIntensity = ret
        return ret
    }

    fileprivate var _maxIntensity: UInt16?
    fileprivate var _medianIntensity: UInt16?
}



