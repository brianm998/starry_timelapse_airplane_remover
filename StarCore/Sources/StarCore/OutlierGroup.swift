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
    func decisionTreeValueAsync(for type: OutlierGroupFeature) async -> Double 
}

// represents a single outler group in a frame
public actor OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable,
                           ClassifiableOutlierGroup
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

    public func getLineScore() async -> Double? {
        // make sure the line is loaded, otherwise no score
        if !lineLoaded { let _ = await self.line() }
        return lineScore         
    }
    
    public func set(line: HoughLineFinder.LineInfo) {
        _line = line.line
        lineScore = line.score
        lineLoaded = true
    }

    public var lineFinder: CombinedHoughLineFinder {
        get async {
            CombinedHoughLineFinder(pixels: Array(self.pixelSet),
                                    bounds: self.bounds,
                                    args: await constants.getHoughLineFinderArgs(),
                                    frameIndex: self.frameIndex)
        }
    }
    
    public func line() async -> Line? {
        if shouldLoadLine {
            if size < 10 {      // XXX constant to help speed up classification of large sets
                shouldLoadLine = false
                return nil
            }
            shouldLoadLine = false
            if let line = await self.lineFinder.line {
                self.set(line: line)
                return line.line
            } else {
                return nil
            }
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
    
    public func shouldPaint(_ shouldPaint: PaintReason, markAsChanged: Bool = true) async {
        //Log.d("\(self) should paint \(shouldPaint) self.frame \(self.frame)")
        self._shouldPaint = shouldPaint

        // XXX update frame that it's different
        if markAsChanged { await self.frame?.markAsChanged() }

        await paintObserver?.set(shouldPaint: shouldPaint)
    }

    // has to be optional so we can read OuterlierGroups as codable
    public weak var frame: FrameAirplaneRemover?

    public func set(frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    private var _originZeroLine: Line?

    // a line with (0,0) origin calculated from the pixels in this group, if possible
    public var originZeroLine: Line? {
        get async {
            if let _originZeroLine { return _originZeroLine }
            if let line = await self.line() {
                _originZeroLine = originZeroLine(from: line)
            }
            return _originZeroLine
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
            //Log.d("have LINE \(line)")
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
            pixelToWrite.red = pixel.intensity
            pixelToWrite.green = pixel.intensity
            pixelToWrite.blue = pixel.intensity
            pixelToWrite.alpha = pixel.intensity

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
    func decisionTreeValues(for treeType: TreeType = .all) async -> [Double] {
        var ret: [Double] = []
        ret.append(Double(self.id))
        for type in OutlierGroupFeature.allCases { // XXX sort order?
            //let t0 = NSDate().timeIntervalSince1970
            if type.isUsed(for: treeType) {
                ret.append(await self.decisionTreeValueAsync(for: type))
            } else {
                ret.append(0)
            }
            //let t1 = NSDate().timeIntervalSince1970
            //Log.i("frame \(frameIndex) group \(self) took \(t1-t0) seconds to calculate value for \(type)")
        }
        return ret
    }
    
    // the ordering of the list of values above
    static var decisionTreeValueTypes: [OutlierGroupFeature] {
        var ret = [OutlierGroupFeature](repeating: .size, count: OutlierGroupFeature.allCases.count)
        for feature in OutlierGroupFeature.allCases {
            ret[feature.sortOrder] = feature
        }
        return ret
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

    nonisolated public func decisionTreeValue(for type: OutlierGroupFeature) -> Double {
//        if let value = featureValueCache[type] { return value }

        //let t0 = NSDate().timeIntervalSince1970

        let ret = type.decisionTreeValueSync(of: self)
        //let t1 = NSDate().timeIntervalSince1970
        //Log.d("group \(id) @ frame \(frameIndex) decisionTreeValue(for: \(type)) = \(ret) after \(t1-t0)s")

//        featureValueCache[type] = ret
        return ret
    }

    public func decisionTreeValueAsync(for type: OutlierGroupFeature) async -> Double {
        if let value = featureValueCache[type] { return value }

        //let t0 = NSDate().timeIntervalSince1970
        let ret = await Task.detached(priority: .userInitiated) {
            await type.decisionTreeValue(of: self)
        }.value

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
    fileprivate var _neighborLineScores: NeighborLineScores?

    public var exisitingNeighborLineScores: NeighborLineScores? { _neighborLineScores }
    
    public func set(neighborLineScores: NeighborLineScores) {
        _neighborLineScores = neighborLineScores
    }
    
    public var neighboringThetaScore: Double {
        get async {
            if let _neighborLineScores { return _neighborLineScores.thetaScore }
            let scores = await self.neighborLineScores
            _neighborLineScores = scores
            return scores.thetaScore
        }
    }

    public var neighboringRhoScore: Double {
        get async {
            if let _neighborLineScores { return _neighborLineScores.rhoScore }
            let scores = await self.neighborLineScores
            _neighborLineScores = scores
            return scores.rhoScore
        }
    }

    public var neighboringSizeScore: Double {
        get async {
            if let _neighborLineScores { return _neighborLineScores.sizeScore }
            let scores = await self.neighborLineScores
            _neighborLineScores = scores
            return scores.sizeScore
        }
    }

    public var neighboringBrightnessScore: Double {
        get async {
            if let _neighborLineScores { return _neighborLineScores.brightnessScore }
            let scores = await self.neighborLineScores
            _neighborLineScores = scores
            return scores.brightnessScore
        }
    }

    public var neighboringDistanceScore: Double {
        get async {
            if let _neighborLineScores { return _neighborLineScores.distanceScore }
            let scores = await self.neighborLineScores
            _neighborLineScores = scores
            return scores.distanceScore
        }
    }

    // collect a bunch of scores related to nearby outliers in neighboring frames
    private var neighborLineScores: NeighborLineScores {
        get async {
            if let _neighborLineScores {
                return _neighborLineScores
            } else if let frame = self.frame,
                      let originalGroupLine = await self.originZeroLine,
                      let previousFrame = await frame.getPreviousFrame(),
                      let previousOutlierGroups = await previousFrame.getOutlierGroups(),
                      let nextFrame = await frame.getNextFrame(),
                      let nextOutlierGroups = await nextFrame.getOutlierGroups()
            {
                let previousOutlierImage = FrameHolder(await previousOutlierGroups.outlierImageDataFunc(),
                                                       width: frame.width, height: frame.height)
                let nextOutlierImage = FrameHolder(await nextOutlierGroups.outlierImageDataFunc(),
                                                   width: frame.width, height: frame.height)
                
                return await StarCore.neighborLineScores(of: self,
                                                         width: frame.width,
                                                         height: frame.height,
                                                         with: previousOutlierGroups,
                                                         and: nextOutlierGroups,
                                                         previousOutlierImage: previousOutlierImage,
                                                         nextOutlierImage: nextOutlierImage,
                                                         originalGroupLine: originalGroupLine)
            } else {
                return NeighborLineScores() // all zeros
            }
        }
    }
}

public func neighborLineScores(of group: OutlierGroup,
                               width: Int,
                               height: Int,
                               with previousOutlierGroups: OutlierGroups,
                               and nextOutlierGroups: OutlierGroups,
                               previousOutlierImage: FrameHolder,
                               nextOutlierImage: FrameHolder,
                               originalGroupLine: Line,
                               // how far to iderate perpendicular to the line
                               iterationWidthPixels: Int = 8,
                               // how far to iterate inside the bounding box
                               maxInnerDistance: Double = 12.0,
                               // how far to iterate outside the bounding box
                               maxOuterDistance: Double = 60.0)
  async -> NeighborLineScores
{
    var scores = NeighborLineScores()

    // XXX XXX XXX
    //if true { return scores }
    // XXX XXX XXX
    /*

     calculate a score which gives a larger value if there is one or more
     lines in neighboring frames which match, given some criteria:

     - rho diff
     - theta diff
     - bounding box distance

     iterate along the blob line similar to the BlobLineExtender,
     but on neighboring frames.

     grab a set of outliers from each neighorbing frame along the iteration line

     */


    var previousNeighbors: Set<UInt16> = []
    var nextNeighbors: Set<UInt16> = []


    let groupBounds = group.bounds
    let groupSize = group.size
    let groupMedianIntensity = await group.medianIntensity()

    var iterationCount = 0

    let intersections = group.bounds.intersections(with: originalGroupLine.standardLine)
    if intersections.count > 1 {
        originalGroupLine.iterate(.forwards,
                                  from: intersections[0],
                                  numberOfAdjecentPixels: iterationWidthPixels)
        { x, y, orientation in
            //Log.d("frame \(self.frameIndex) iterating for group \(group) at [\(x), \(y)]")
            if x < 0 || y < 0 || x >= width || y >= height { return false }

            let distance = intersections[0].distance(to: x, and: y)
            if distance > maxInnerDistance,
               groupBounds.contains(x: x, y: y) { return false }
            if distance > maxOuterDistance { return false } 
            
            let previousId = previousOutlierImage.value(at: x, and: y)
            let nextId = nextOutlierImage.value(at: x, and: y)

            if previousId != 0 { previousNeighbors.insert(previousId) }
            if nextId != 0 { nextNeighbors.insert(nextId) }
            iterationCount += 1
            return true
        }

        originalGroupLine.iterate(.backwards,
                                  from: intersections[0],
                                  numberOfAdjecentPixels: iterationWidthPixels)
        { x, y, orientation in
            //Log.d("frame \(self.frameIndex) iterating for group \(group) at [\(x), \(y)]")
            if x < 0 || y < 0 || x >= width || y >= height { return false }
            
            let distance = intersections[0].distance(to: x, and: y)
            if distance > maxInnerDistance,
               groupBounds.contains(x: x, y: y)  { return false }
            if distance > maxOuterDistance { return false } 
            
            let previousId = previousOutlierImage.value(at: x, and: y)
            let nextId = nextOutlierImage.value(at: x, and: y)

            if previousId != 0 { previousNeighbors.insert(previousId) }
            if nextId != 0 { nextNeighbors.insert(nextId) }
            iterationCount += 1
            return true
        }
        //Log.d("frame \(frameIndex) processing blob \(blob) iterating forwards from intersection 1")
        originalGroupLine.iterate(.forwards,
                                  from: intersections[1],
                                  numberOfAdjecentPixels: iterationWidthPixels)
        { x, y, orientation in
            //Log.d("frame \(self.frameIndex) iterating for group \(group) at [\(x), \(y)]")
            if x < 0 || y < 0 || x >= width || y >= height { return false }
            
            let distance = intersections[0].distance(to: x, and: y)
            if distance > maxInnerDistance,
               groupBounds.contains(x: x, y: y)  { return false }
            if distance > maxOuterDistance { return false } 
            
            let previousId = previousOutlierImage.value(at: x, and: y)
            let nextId = nextOutlierImage.value(at: x, and: y)
              
            if previousId != 0 { previousNeighbors.insert(previousId) }
            if nextId != 0 { nextNeighbors.insert(nextId) }
            iterationCount += 1
            return true
        }
        //Log.d("frame \(frameIndex) processing blob \(blob) iterating backwards from intersection 1")
        originalGroupLine.iterate(.backwards,
                                  from: intersections[1],
                                  numberOfAdjecentPixels: iterationWidthPixels)
        { x, y, orientation in
            //Log.d("frame \(self.frameIndex) iterating for group \(group) at [\(x), \(y)]")

            if x < 0 || y < 0 || x >= width || y >= height { return false }
            
            let distance = intersections[0].distance(to: x, and: y)
            if distance > maxInnerDistance,
               groupBounds.contains(x: x, y: y)  { return false }
            if distance > maxOuterDistance { return false } 
            
            let previousId = previousOutlierImage.value(at: x, and: y)
            let nextId = nextOutlierImage.value(at: x, and: y)
              
            if previousId != 0 { previousNeighbors.insert(previousId) }
            if nextId != 0 { nextNeighbors.insert(nextId) }
            iterationCount += 1
            return true
        }
    }

    // here we have a set of previousNeighbors and nextNeighbors

    /*
     compute the score to be maximal when there is a nearby group that:
     - has a close line theta and rho
     - is closer rather than farther away
     - tends towards zero when they are farther away
     
     theta score is 1 if they are parallel, 0 if they are perpendicular
     rho score is 1 if they are identical, decreases with square of distance
     distance score is 1 if they touch, decreases with square of distance
     size score is 1 if they are the same size, smallest / largest otherwise
     
     final score per outlying group is muliple of all

     final score is sum of all outying group matches
     */

    //Log.d("frame \(self.frameIndex) found \(previousNeighbors.count) previousNeighbors and  \(nextNeighbors.count) nextNeighbors for group \(self) iterationCount \(iterationCount)")
    
    for previousId in previousNeighbors {
        if let previousOutlier = await previousOutlierGroups.get(with: previousId),
           let previousOutlierLine = await previousOutlier.originZeroLine
        {
            let otherGroupMedianIntensiy = await previousOutlier.medianIntensity()
            scores = scores + scoresOf(originalGroupLine: originalGroupLine,
                                       previousOutlierLine: previousOutlierLine,
                                       groupBounds: groupBounds,
                                       groupSize: groupSize,
                                       groupMedianIntensity: groupMedianIntensity,
                                       otherOutlier: previousOutlier,
                                       otherGroupMedianIntensiy: otherGroupMedianIntensiy)
        }
    }
    
    for nextId in nextNeighbors {
        if let nextOutlier = await nextOutlierGroups.get(with: nextId),
           let nextOutlierLine = await nextOutlier.originZeroLine
        {
            let otherGroupMedianIntensiy = await nextOutlier.medianIntensity()
            scores = scores + scoresOf(originalGroupLine: originalGroupLine,
                                       previousOutlierLine: nextOutlierLine,
                                       groupBounds: groupBounds,
                                       groupSize: groupSize,
                                       groupMedianIntensity: groupMedianIntensity,
                                       otherOutlier: nextOutlier,
                                       otherGroupMedianIntensiy: otherGroupMedianIntensiy)
        }
    }
    return scores
}

fileprivate func scoresOf(originalGroupLine: Line,
                          previousOutlierLine: Line,
                          groupBounds: BoundingBox,
                          groupSize: UInt,
                          groupMedianIntensity: UInt16,
                          otherOutlier: OutlierGroup,
                          otherGroupMedianIntensiy: UInt16) -> NeighborLineScores
{
    // calculate size score
    // 1 if they are the same, trending towards zero as they diverge
    var sizeScore = 0.0
    if otherOutlier.size > groupSize {
        sizeScore = Double(groupSize) / Double(otherOutlier.size)
    } else {
        sizeScore = Double(otherOutlier.size) / Double(groupSize)
    }

    // calculate brightness score
    // 1 if they are the same, trending towards zero as they diverge
    var brightnessScore = 0.0
    if otherGroupMedianIntensiy > groupMedianIntensity {
        brightnessScore = Double(groupMedianIntensity)/Double(otherGroupMedianIntensiy)
    } else {
        brightnessScore = Double(otherGroupMedianIntensiy)/Double(groupMedianIntensity)
    }

    // calculate distance score
    var edgeDistance = groupBounds.edgeDistance(to: otherOutlier.bounds)
    if edgeDistance < 1 { edgeDistance = 1 }

    // 1 if they are close, trending towards zero as they diverge
    let distanceScore = 1/edgeDistance
    
    return NeighborLineScores(thetaScore: thetaScore(of: originalGroupLine,
                                                     and: previousOutlierLine),
                              rhoScore: rhoScore(of: originalGroupLine,
                                                 and: previousOutlierLine),
                              sizeScore: sizeScore,
                              brightnessScore: brightnessScore,
                              distanceScore: distanceScore)
}

fileprivate func thetaScore(of line1: Line, and line2: Line) -> Double {
    // theta score is 1 if they are parallel, 0 if they are perpendicular
    
    var theta1 = line1.theta
    var theta2 = line2.theta

    if theta1 < 0 { theta1 += 360 }
    if theta2 < 0 { theta2 += 360 }

    // thetas are now both positive
    
    var thetaDiff = abs(theta1-theta2)

    if thetaDiff > 180 { thetaDiff = 360-thetaDiff }
    // thetaDiff is now between 0 and 180

    if thetaDiff > 90 { thetaDiff = 180-thetaDiff }

    // thetaDiff is now between 0 and 90
    
    // 1 if thetaDiff == 0
    // 0 if thetaDiff == 90
    let thetaScore = (90-thetaDiff)/90
    
    return thetaScore
}

fileprivate func rhoScore(of line1: Line, and line2: Line) -> Double {

    // rho score is 1 if they are identical, zero if 100 pixels away or more
    let max = 100.0             // XXX constant
    
    var distance = abs(line1.rho - line2.rho)
    if distance > max { distance = max }
    let rhoScore = (max-distance)/max
    
    return rhoScore
}

