/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// https://stackoverflow.com/questions/63018581/fastest-way-to-save-structs-ios-swift
// XXX look into ContiguousBytes

import Foundation
import Cocoa

// XXX make a method that gathers all classifier features at once, and keeps them for later

// these need to be setup at startup so the decision tree values are right
internal var IMAGE_WIDTH: Double?
internal var IMAGE_HEIGHT: Double?

// represents a single outler group in a frame
@available(macOS 10.15, *) 
public actor OutlierGroup: CustomStringConvertible,
                           Hashable,
                           Equatable,
                           Comparable,
                           Decodable // can't be an actor and codable :(
{
    public let name: String
    public let size: UInt              // number of pixels in this outlier group
    public let bounds: BoundingBox     // a bounding box on the image that contains this group
    public let brightness: UInt        // the average amount per pixel of brightness over the limit 
    public let lines: [Line]           // sorted lines from the hough transform of this outlier group

    // pixel value is zero if pixel is not part of group,
    // otherwise it's the amount brighter this pixel was than those in the adjecent frames 
    public let pixels: [UInt32]        // indexed by y * bounds.width + x

    public let max_pixel_distance: UInt16
    public let surfaceAreaToSizeRatio: Double

    // after init, shouldPaint is usually set to a base value based upon different statistics 
    public var shouldPaint: PaintReason? // should we paint this group, and why?

    public let frame_index: Int

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
         max_pixel_distance: UInt16) async
    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
        self.frame_index = frame.frame_index
        self.frame = frame
        self.pixels = pixels
        self.max_pixel_distance = max_pixel_distance
        self.surfaceAreaToSizeRatio = surface_area_to_size_ratio(of: pixels,
                                                                 width: bounds.width,
                                                                 height: bounds.height)
        // do a hough transform on just this outlier group
        let transform = HoughTransform(data_width: bounds.width,
                                       data_height: bounds.height,
                                       input_data: pixels,
                                       max_pixel_distance: max_pixel_distance)

        // we want all the lines, all of them.
        self.lines = transform.lines(min_count: 1)
    }

    public static func == (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name == rhs.name && lhs.frame_index == rhs.frame_index
    }
    
    public static func < (lhs: OutlierGroup, rhs: OutlierGroup) -> Bool {
        return lhs.name < rhs.name
    }
    
    nonisolated public var description: String {
        "outlier group \(frame_index).\(name) size \(size) "
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(frame_index)
    }
    
    public func shouldPaint(_ should_paint: PaintReason) async {
        //Log.d("\(self) should paint \(should_paint)")
        self.shouldPaint = should_paint

        // XXX update frame that it's different 
        await self.frame?.markAsChanged()
    }

    // outputs an image the same size as this outlier's bounding box,
    // coloring the outlier pixels red if will paint, green if not
    public func testImage() -> CGImage? {
        let bytesPerPixel = 64/8
        
        var image_data = Data(count: self.bounds.width*self.bounds.height*bytesPerPixel)
        for x in 0 ..< self.bounds.width {
            for y in 0 ..< self.bounds.height {
                let pixel_index = y*self.bounds.width + x
                var pixel = Pixel()
                if self.pixels[pixel_index] != 0 {
                    // the real color is set in the view layer 
                    pixel.red = 0xFFFF
                    pixel.green = 0xFFFF
                    pixel.blue = 0xFFFF
                    pixel.alpha = 0xFFFF

                    var nextValue = pixel.value
                    
                    let offset = (Int(y) * bytesPerPixel*self.bounds.width) + (Int(x) * bytesPerPixel)
                    
                    image_data.replaceSubrange(offset ..< offset+bytesPerPixel,
                                               with: &nextValue,
                                               count: bytesPerPixel)

                }
            }
        }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let dataProvider = CGDataProvider(data: image_data as CFData) {
            return CGImage(width: self.bounds.width,
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
        } else {
            return nil
        }
    }
    
    // how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
    @available(macOS 10.15, *)
    func pixelOverlap(with group_2: OutlierGroup) async -> Double // 1 means total overlap, 0 means none
    {
        let group_1 = self
        // throw out non-overlapping frames, do any slip through?
        if group_1.bounds.min.x > group_2.bounds.max.x || group_1.bounds.min.y > group_2.bounds.max.y { return 0 }
        if group_2.bounds.min.x > group_1.bounds.max.x || group_2.bounds.min.y > group_1.bounds.max.y { return 0 }

        var min_x = group_1.bounds.min.x
        var min_y = group_1.bounds.min.y
        var max_x = group_1.bounds.max.x
        var max_y = group_1.bounds.max.y
        
        if group_2.bounds.min.x > min_x { min_x = group_2.bounds.min.x }
        if group_2.bounds.min.y > min_y { min_y = group_2.bounds.min.y }
        
        if group_2.bounds.max.x < max_x { max_x = group_2.bounds.max.x }
        if group_2.bounds.max.y < max_y { max_y = group_2.bounds.max.y }
        
        // XXX could search a smaller space probably

        var overlap_pixel_amount = 0;
        
        for x in min_x ... max_x {
            for y in min_y ... max_y {
                let outlier_1_index = (y - group_1.bounds.min.y) * group_1.bounds.width + (x - group_1.bounds.min.x)
                let outlier_2_index = (y - group_2.bounds.min.y) * group_2.bounds.width + (x - group_2.bounds.min.x)
                if outlier_1_index > 0,
                   outlier_1_index < group_1.pixels.count,
                   group_1.pixels[outlier_1_index] != 0,
                   outlier_2_index > 0,
                   outlier_2_index < group_2.pixels.count,
                   group_2.pixels[outlier_2_index] != 0
                {
                    overlap_pixel_amount += 1
                }
            }
        }

        if overlap_pixel_amount > 0 {
            let avg_group_size = (Double(group_1.size) + Double(group_2.size)) / 2
            return Double(overlap_pixel_amount)/avg_group_size
        }
        
        return 0
    }


    
    // manual Decodable conformance so this class can be an actor
    // Encodable conformance is left to the non-actor class OutlierGroupEncodable
    enum CodingKeys: String, CodingKey {
        case name
        case size
        case bounds
        case brightness
        case lines
        case pixels
        case max_pixel_distance
        case surfaceAreaToSizeRatio
        case shouldPaint
        case frame_index
    }

    // XXX this is slow as fuck
    public init(from decoder: Decoder) throws {
	let data = try decoder.container(keyedBy: CodingKeys.self)

        self.name = try data.decode(String.self, forKey: .name)
        self.size = try data.decode(UInt.self, forKey: .size)
        self.bounds = try data.decode(BoundingBox.self, forKey: .bounds)
        self.brightness = try data.decode(UInt.self, forKey: .brightness)
        self.pixels = try data.decode(Array<UInt32>.self, forKey: .pixels) // XXX UInt16?
        self.max_pixel_distance = try data.decode(UInt16.self, forKey: .max_pixel_distance)
        self.surfaceAreaToSizeRatio = try data.decode(Double.self, forKey: .surfaceAreaToSizeRatio)
        self.shouldPaint = try data.decode(PaintReason.self, forKey: .shouldPaint) // XXX move out
        self.frame_index = try data.decode(Int.self, forKey: .frame_index)

        if false {
            // XXX this calculates the lines instead of loading them
            // however it appears to be slower
            
            // the lines are calculated from saved data, not saved themselves
            let transform = HoughTransform(data_width: bounds.width,
                                           data_height: bounds.height,
                                           input_data: pixels,
                                           max_pixel_distance: max_pixel_distance)

            // we want all the lines, all of them.
            self.lines = transform.lines(min_count: 1)
        } else {
            self.lines = try data.decode(Array<Line>.self, forKey: .lines)
        }
    }

    public func encodable() -> OutlierGroupEncodable {
        return OutlierGroupEncodable(name: self.name,
                                     size: self.size,
                                     bounds: self.bounds,
                                     brightness: self.brightness,
                                     lines: self.lines,
                                     pixels: self.pixels,
                                     max_pixel_distance: self.max_pixel_distance,
                                     surfaceAreaToSizeRatio: self.surfaceAreaToSizeRatio,
                                     shouldPaint: self.shouldPaint,
                                     frame_index: self.frame_index)
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
                //Log.d("frame \(frame_index) type \(type) value \(value)")
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
            fatalError("called with bad value \(type)")
        }
    }

    fileprivate var featureValueCache: [Feature: Double] = [:]

    public func clearFeatureValueCache() { featureValueCache = [:] }
    
    public func decisionTreeValue(for type: Feature) async -> Double {
        Log.d("group \(name) @ frame \(frame_index) decisionTreeValue(for: \(type))")

        if let value = featureValueCache[type] { return value }
        
        switch type {
        case .numberOfNearbyOutliersInSameFrame:
            return await self.numberOfNearbyOutliersInSameFrame
        case .adjecentFrameNeighboringOutliersBestTheta:
            return await self.adjecentFrameNeighboringOutliersBestTheta
        case .histogramStreakDetection:
            return await self.histogramStreakDetection
        case .longerHistogramStreakDetection:
            return await self.longerHistogramStreakDetection
        case .neighboringInterFrameOutlierThetaScore:
            return await self.neighboringInterFrameOutlierThetaScore
        case .maxOverlap:
            return await self.maxOverlap
        case .maxOverlapTimesThetaHisto:
            return await self.maxOverlapTimesThetaHisto
        default:
            return self.nonAsyncDecisionTreeValue(for: type)
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
               let nearby_groups = await frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                             of: self.bounds)
            {
                return Double(nearby_groups.count)
            } else {
                fatalError("SHIT")
            }
        }
    }

    // use these to compare outliers in same and different frames
    var houghLineHistogram: HoughLineHistogram {
        let lines = self.lines                            // try to copy
        return HoughLineHistogram(withDegreeIncrement: 5, // XXX hardcoded 5
                                  lines: lines,
                                  andGroupSize: self.size)
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
    fileprivate func thetaScore(between theta_1: Double, and theta_2: Double) -> Double {

        var theta_1_opposite = theta_1 + 180
        if theta_1_opposite > 360 { theta_1_opposite -= 360 }

        var opposite_difference = theta_1_opposite - theta_2

        if opposite_difference <   0 { opposite_difference += 360 }
        if opposite_difference > 360 { opposite_difference -= 360 }

        return opposite_difference / 180.0
    }
    
    // tries to find a streak with hough line histograms
    fileprivate var histogramStreakDetection: Double {
        get async {
            if let frame = frame {
                var best_score = 0.0
                let selfHisto = self.houghLineHistogram

                if let previous_frame = await frame.previousFrame,
                   let nearby_groups = await previous_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                          of: self.bounds)
                {
                    for group in nearby_groups {
                        let score = await self.thetaHistoCenterLineScore(with: group,
                                                                         selfHisto: selfHisto)
                        best_score = max(score, best_score)
                    }
                }
                if let next_frame = await frame.nextFrame,
                   let nearby_groups = await next_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                      of: self.bounds)
                {
                    for group in nearby_groups {
                        let score = await self.thetaHistoCenterLineScore(with: group,
                                                                         selfHisto: selfHisto)
                        best_score = max(score, best_score)
                    }
                }
                return best_score
            } else {
                fatalError("SHIT")
            }
        }
    }

    // a score based upon a comparsion of the theta histograms of the this and another group,
    // as well as how well the theta of the other group corresponds to the center line theta between them
    fileprivate func thetaHistoCenterLineScore(with group: OutlierGroup,
                                           selfHisto: HoughLineHistogram? = nil) async -> Double
    {
        var histo = selfHisto
        if histo == nil { histo = self.houghLineHistogram }
        let center_line_theta = self.bounds.centerTheta(with: group.bounds)
        let other_histo = await group.houghLineHistogram
        let histo_score = other_histo.matchScore(with: histo!)
        let theta_score = thetaScore(between: center_line_theta, and: other_histo.maxTheta)
        return histo_score*theta_score
    }
    
    // tries to find a streak with hough line histograms
    // make this recursive to go back 3 frames in each direction
    fileprivate var longerHistogramStreakDetection: Double {
        get async {
            let number_of_frames = 10 // how far in each direction to go
            let forwardScore = await self.streakScore(in: .forwards, numberOfFramesLeft: number_of_frames)
            let backwardScore = await self.streakScore(in: .backwards, numberOfFramesLeft: number_of_frames)
            return forwardScore + backwardScore
        }
    }

    fileprivate var maxOverlap: Double {
        get async {
            var maxOverlap = 0.0
            if let frame = frame {
                if let previous_frame = await frame.previousFrame,
                   let nearby_groups = await previous_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                          of: self.bounds)
                {
                    for group in nearby_groups {
                        maxOverlap = max(await self.pixelOverlap(with: group), maxOverlap)
                    }
                }
                
                if let next_frame = await frame.nextFrame,
                   let nearby_groups = await next_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                      of: self.bounds)
                {
                    for group in nearby_groups {
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

                if let previous_frame = await frame.previousFrame,
                   let nearby_groups = await previous_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                          of: self.bounds)
                {
                    for group in nearby_groups {
                        let otherHisto = await group.houghLineHistogram
                        let histo_score = otherHisto.matchScore(with: selfHisto)
                        let overlap = await self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histo_score, maxOverlap)
                    }
                }
                
                if let next_frame = await frame.nextFrame,
                   let nearby_groups = await next_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                      of: self.bounds)
                {
                    for group in nearby_groups {
                        let otherHisto = await group.houghLineHistogram
                        let histo_score = otherHisto.matchScore(with: selfHisto)
                        let overlap = await self.pixelOverlap(with: group)
                        maxOverlap = max(overlap * histo_score, maxOverlap)
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
               let nearby_groups = await frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                             of: self.bounds)
            {
                let selfHisto = self.houghLineHistogram
                var ret = 0.0
                var count = 0
                for group in nearby_groups {
                    if group.name == self.name { continue }
                    let center_line_theta = self.bounds.centerTheta(with: group.bounds)
                    let otherHisto = await group.houghLineHistogram
                    let other_theta_score = thetaScore(between: center_line_theta, and: otherHisto.maxTheta)
                    let self_theta_score = thetaScore(between: center_line_theta, and: selfHisto.maxTheta)
                    let histo_score = otherHisto.matchScore(with: selfHisto)

                    // modify this score by how close the theta of
                    // the line between the outlier groups center points
                    // is to the the theta of both of them
                    ret += self_theta_score * other_theta_score * histo_score
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
                let this_theta = self.firstLine?.theta ?? 180
                var smallest_difference: Double = 360
                if let previous_frame = await frame.previousFrame,
                   let nearby_groups =
                     await previous_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                            of: self.bounds)
                {

                    for group in nearby_groups {
                        if let firstLine = await group.firstLine {
                            let difference = Double(abs(this_theta - firstLine.theta))
                            if difference < smallest_difference {
                                smallest_difference = difference
                            }
                        }
                    }
                }

                if let next_frame = await frame.nextFrame,
                   let nearby_groups = await next_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                                      of: self.bounds)
                {
                    for group in nearby_groups {
                        if let firstLine = await group.firstLine {
                            let difference = Double(abs(this_theta - firstLine.theta))
                            if difference < smallest_difference {
                                smallest_difference = difference
                            }
                        }
                    }
                }
                
                return smallest_difference
            } else {
                fatalError("SHIT")
            }
        }
    }

    fileprivate var maxThetaDiffOfFirst10HoughLines: Double {
        var max_diff = 0.0
        let first_theta = self.lines[0].theta
        var max = 10;
        if self.lines.count < max { max = self.lines.count }
        for i in 0..<max {
            let this_theta = self.lines[i].theta
            let this_diff = abs(this_theta - first_theta)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    fileprivate var maxRhoDiffOfFirst10HoughLines: Double {
        var max_diff = 0.0
        let first_rho = self.lines[0].rho
        var max = 10;
        if self.lines.count < max { max = self.lines.count }
        for i in 0..<max {
            let this_rho = self.lines[i].rho
            let this_diff = abs(this_rho - first_rho)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
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
        var max_diff = 0.0
        let first_theta = self.lines[0].theta
        for i in 1..<self.lines.count {
            let this_theta = self.lines[i].theta
            let this_diff = abs(this_theta - first_theta)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    fileprivate var maxRhoDiffOfAllHoughLines: Double {
        var max_diff = 0.0
        let first_rho = self.lines[0].rho
        for i in 1..<self.lines.count {
            let this_rho = self.lines[i].rho
            let this_diff = abs(this_rho - first_rho)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
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

    

    @available(macOS 10.15, *)
    fileprivate func streakScore(in direction: StreakDirection,
                     numberOfFramesLeft: Int,
                     existingValue: Double = 0) async -> Double
    {
        let selfHisto = self.houghLineHistogram
        var best_score = 0.0
        var bestGroup: OutlierGroup?
        
        if let frame = self.frame,
           let other_frame = direction == .forwards ? await frame.nextFrame : await frame.previousFrame,
           let nearby_groups = await other_frame.outlierGroups(within: self.maxNearbyGroupDistance,
                                                               of: self.bounds)
        {
            for nearby_group in nearby_groups {
                let score = await self.thetaHistoCenterLineScore(with: nearby_group,
                                                                 selfHisto: selfHisto)
                best_score = max(score, best_score)
                if score == best_score {
                    bestGroup = nearby_group
                }
            }
        }

        let score = existingValue + best_score
        
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
        
        //max_pixel_distance: UInt16
        size += 2
        
        //surfaceAreaToSizeRatio: Double (64 bits)
        size += 8

        return size
    }

    public init(withName name: String,
                frameIndex frame_index: Int,
                with persitentData: Data) {
        var index: Int = 0

        self.name = name
        self.frame_index = frame_index
        
        let size_data = persitentData.subdata(in: index..<index+8)
        self.size = size_data.withUnsafeBytes { $0.load(as: UInt.self).bigEndian }
        index += 8

        //Log.d("\(self.name) read size \(self.size)")
        
        let bb_min_x_data = persitentData.subdata(in: index..<index+8)
        let bb_min_x = bb_min_x_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bb_min_y_data = persitentData.subdata(in: index..<index+8)
        let bb_min_y = bb_min_y_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bb_max_x_data = persitentData.subdata(in: index..<index+8)
        let bb_max_x = bb_max_x_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        let bb_max_y_data = persitentData.subdata(in: index..<index+8)
        let bb_max_y = bb_max_y_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        self.bounds = BoundingBox(min: Coord(x: bb_min_x, y: bb_min_y),
                                  max: Coord(x: bb_max_x, y: bb_max_y))

        let brightness_data = persitentData.subdata(in: index..<index+8)
        self.brightness = brightness_data.withUnsafeBytes { $0.load(as: UInt.self).bigEndian }
        index += 8

        let lines_count_data = persitentData.subdata(in: index..<index+8)
        let lines_count = lines_count_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        //Log.d("lines_count \(lines_count) index \(index) persitentData.count \(persitentData.count)")
        
        var _lines: [Line] = []
        
        for i in 0..<lines_count {
            let theta_data = persitentData.subdata(in: index..<index+8)
            let theta = theta_data.withUnsafeBytes { $0.load(as: Double.self) }
            index += 8

            let rho_data = persitentData.subdata(in: index..<index+8)
            let rho = rho_data.withUnsafeBytes { $0.load(as: Double.self) }
            index += 8
            
            let count_data = persitentData.subdata(in: index..<index+8)
            let count = count_data.withUnsafeBytes { $0.load(as: Int.self) }
            index += 8
            
            _lines.append(Line(theta: theta, rho: rho, count: count))
        }
        self.lines = _lines

        let pixels_count_data = persitentData.subdata(in: index..<index+8)
        let pixels_count = pixels_count_data.withUnsafeBytes { $0.load(as: Int.self).bigEndian }
        index += 8

        var pixels: [UInt32] = []

        //Log.d("pixels_count \(pixels_count) index \(index) persitentData.count \(persitentData.count)")
        
        for i in 0..<pixels_count {
            let pixel_data = persitentData.subdata(in: index..<index+4)
            index += 4
            let pixel = pixel_data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            pixels.append(pixel)
        }
        self.pixels = pixels
        
        let mpdd = persitentData.subdata(in: index..<index+2)
        self.max_pixel_distance = mpdd.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        index += 2

        let satsrd = persitentData.subdata(in: index..<index+8)
        self.surfaceAreaToSizeRatio = satsrd.withUnsafeBytes { $0.load(as: Double.self) }
        index += 8
        
        // surfaceAreaToSizeRatio
    }
    
    public var persistentData: Data {

        let size = self.persistentDataSizeBytes
        var data = Data(repeating: 0, count: size)

        //Log.d("\(self.name) creating persistent data of size \(size)")

        var index: Int = 0

        let size_data = withUnsafeBytes(of: self.size.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: size_data)
        index += 8
        
        //Log.d("\(self.name) size \(self.size)")

        let bb_min_x = self.bounds.min.x
        let bb_min_x_data = withUnsafeBytes(of: bb_min_x.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bb_min_x_data)
        index += 8
        
        let bb_min_y = self.bounds.min.y
        let bb_min_y_data = withUnsafeBytes(of: bb_min_y.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bb_min_y_data)
        index += 8
        
        let bb_max_x = self.bounds.max.x
        let bb_max_x_data = withUnsafeBytes(of: bb_max_x.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bb_max_x_data)
        index += 8

        let bb_max_y = self.bounds.max.y
        let bb_max_y_data = withUnsafeBytes(of: bb_max_y.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: bb_max_y_data)
        index += 8

        let brightness_data = withUnsafeBytes(of: self.brightness.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: brightness_data)
        index += 8

        let num_lines = self.lines.count
        let num_lines_data = withUnsafeBytes(of: num_lines.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: num_lines_data)
        index += 8

        //Log.d("\(self.name) self.lines.count \(self.lines.count)")

        for line in self.lines {
            let theta_data = withUnsafeBytes(of: line.theta) { Data($0) }
            data.replaceSubrange(index..<index+8, with: theta_data)
            index += 8
            let rho_data = withUnsafeBytes(of: line.rho) { Data($0) }
            data.replaceSubrange(index..<index+8, with: rho_data)
            index += 8
            let count_data = withUnsafeBytes(of: line.count.bigEndian) { Data($0) }
            data.replaceSubrange(index..<index+8, with: count_data)
            index += 8
        }

        let num_pixels = self.pixels.count
        
        //Log.d("\(self.name) self.pixels.count \(self.pixels.count)")

        let num_pixels_data = withUnsafeBytes(of: num_pixels.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+8, with: num_pixels_data)
        index += 8

        for i in 0..<num_pixels {
            let pixel_data = withUnsafeBytes(of: self.pixels[i].bigEndian) { Data($0) }
            data.replaceSubrange(index..<index+4, with: pixel_data)
            index += 4
        }

        let mpdd = withUnsafeBytes(of: self.max_pixel_distance.bigEndian) { Data($0) }
        data.replaceSubrange(index..<index+2, with: mpdd)
        index += 2

        data.replaceSubrange(index..<index+8,
                             with: withUnsafeBytes(of: self.surfaceAreaToSizeRatio) { Data($0) })
        index += 8

        return data        
    }

    static let data_bin_suffix = "outlier-data.bin"
    static let paint_json_suffix = "paint.json"
    
    public func writeToFile(in dir: String) async throws {
        let filename = "\(dir)/\(self.name)-\(OutlierGroup.data_bin_suffix)"

        if file_manager.fileExists(atPath: filename) {
            Log.i("not overwriting already existing filename \(filename)")
            //try file_manager.removeItem(atPath: filename)
        } else {
            let data = self.persistentData
            
            file_manager.createFile(atPath: filename,
                                    contents: data,
                                    attributes: nil)
        }
        if let shouldPaint = self.shouldPaint {
            // also write out a separate json file with paint reason
            let filename = "\(dir)/\(self.name)-\(OutlierGroup.paint_json_suffix)"

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            let json_data = try encoder.encode(shouldPaint)
            if file_manager.fileExists(atPath: filename) {
                Log.i("removing already existing paint reason \(filename)")
                try file_manager.removeItem(atPath: filename)
            } 
            Log.i("creating \(filename)")                      
            file_manager.createFile(atPath: filename,
                                    contents: json_data,
                                    attributes: nil)
        }
    }
}

/*
 xxx XXX XXX
 XXX XXX XXX
 XXX XXX XXX

 Plan for ditching BinaryCodable for saving outlier groups:

 instead of writing out a single file for all outliers in a frame,
 create a directory named by the frame index and each file in it
 is a file named by the name of the outlier group contained within.

 move should paint reason to a separate json sidecar '-should-paint' file

 read and write a binary structure like this
 
 size: UInt           (64 bits)
 bounds: BoundingBox  (four 64 bit Ints)
 brightness: UInt     (64 bits)
 number_lines:        (64 bits)
 lines: [Line]        [three 64 bit values]
 number_pixels        (64 bits)
 pixels: [UInt32]
 max_pixel_distance: UInt16
 surfaceAreaToSizeRatio: Double (64 bits)

 
 XXX XXX XXX
 XXX XXX XXX
 XXX XXX XXX
 */
// this class is a property by property copy of an OutlierGroup,
// but not an actor so it's both encodable and usable by the view layer
public class OutlierGroupEncodable: Encodable {
    public let name: String
    public let size: UInt
    public let bounds: BoundingBox
    public let brightness: UInt   
    public let lines: [Line]
    public let pixels: [UInt32]   
    public let max_pixel_distance: UInt16
    public let surfaceAreaToSizeRatio: Double
    public var shouldPaint: PaintReason?
    public let frame_index: Int

    public init(name: String,
                size: UInt,
                bounds: BoundingBox,
                brightness: UInt,
                lines: [Line],
                pixels: [UInt32],
                max_pixel_distance: UInt16,
                surfaceAreaToSizeRatio: Double,
                shouldPaint: PaintReason?,
                frame_index: Int)
    {
        self.name = name
        self.size = size
        self.bounds = bounds
        self.brightness = brightness
        self.lines = lines
        self.pixels = pixels
        self.max_pixel_distance = max_pixel_distance
        self.surfaceAreaToSizeRatio = surfaceAreaToSizeRatio
        self.shouldPaint = shouldPaint
        self.frame_index = frame_index
    }
}

public func surface_area_to_size_ratio(of pixels: [UInt32], width: Int, height: Int) -> Double {
    var size: Int = 0
    var surface_area: Int = 0
    for x in 0 ..< width {
        for y in 0 ..< height {
            let index = y * width + x

            if pixels[index] != 0 {
                size += 1

                var has_top_neighbor = false
                var has_bottom_neighbor = false
                var has_left_neighbor = false
                var has_right_neighbor = false
                
                if x > 0 {
                    if pixels[y * width + x - 1] != 0 {
                        has_left_neighbor = true
                    }
                }
                if y > 0 {
                    if pixels[(y - 1) * width + x] != 0 {
                        has_top_neighbor = true
                    }
                }
                if x + 1 < width {
                    if pixels[y * width + x + 1] != 0 {
                        has_right_neighbor = true
                    }
                }
                if y + 1 < height {
                    if pixels[(y + 1) * width + x] != 0 {
                        has_bottom_neighbor = true
                    }
                }
                
                if has_top_neighbor,
                   has_bottom_neighbor,
                   has_left_neighbor,
                   has_right_neighbor
                {
                    
                } else {
                    surface_area += 1
                }
            }
        }
    }
    return Double(surface_area)/Double(size)
}

fileprivate let file_manager = FileManager.default
