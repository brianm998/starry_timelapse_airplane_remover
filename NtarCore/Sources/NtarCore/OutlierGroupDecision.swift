import Foundation

/*
 This OutlierGroup extention contains all of the decision tree specific logic.

 Adding a new case to the TreeDecisionType and giving a value for it in decisionTreeValue
 is all needed to add a new value to the decision tree criteria
 
 */

@available(macOS 10.15, *) 
public struct OutlierGroupValueMap {
    public var values: [OutlierGroup.TreeDecisionType: Double] = [:]
    public init() { }
}

public struct HoughLineHistogram {

    let values: [Double]
    let increment: Int          // degree difference between indexes of values above
        
    init(withDegreeIncrement increment: Int,
         lines: [Line],
         andGroupSize groupSize: UInt) {
        self.increment = increment

        var values = Array<Double>(repeating: 0, count: 360/increment)

        for line in lines {
            let index = Int(line.theta/Double(increment))
            values[index] += Double(line.count)/Double(groupSize)
        }

        self.values = values
    }

    func matchScore(with other: HoughLineHistogram) -> Double {
        if self.increment != other.increment { return 0 }

        var ret = 0.0
        
        for (index, value) in values.enumerated() {
            let other_value = other.values[index]
            let min = min(value, other_value)
            ret = max(min, ret)
        }
        return ret
    }
}

// used for storing only decision tree data for all of the outlier groups in a frame
@available(macOS 10.15, *) 
public class OutlierGroupValueMatrix: Codable {
    public var types: [OutlierGroup.TreeDecisionType] = OutlierGroup.decisionTreeValueTypes

    public struct OutlierGroupValues: Codable {
        public let shouldPaint: Bool
        public let values: [Double]
    }
    
    public var values: [OutlierGroupValues] = []      // indexed by outlier group first then types later
    
    public func append(outlierGroup: OutlierGroup) async {
        let shouldPaint = await outlierGroup.shouldPaint!
        values.append(OutlierGroupValues(shouldPaint: shouldPaint.willPaint,
                                         values: await outlierGroup.decisionTreeValues))
    }
    
    public var outlierGroupValues: ([OutlierGroupValueMap], [OutlierGroupValueMap]) {
        var shouldPaintRet: [OutlierGroupValueMap] = []
        var shoultNotPaintRet: [OutlierGroupValueMap] = []
        for value in values {
            var groupValues = OutlierGroupValueMap()
            for (index, type) in types.enumerated() {
                groupValues.values[type] = value.values[index]
            }
            if(value.shouldPaint) {
                shouldPaintRet.append(groupValues)
            } else {
                shoultNotPaintRet.append(groupValues)
            }
        }
        return (shouldPaintRet, shoultNotPaintRet)
    }

    public var prettyJson: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(self)
            if let json_string = String(data: data, encoding: .utf8) {
                return json_string
            }
        } catch {
            Log.e("\(error)")
        }
        return nil
    }
}

@available(macOS 10.15, *) 
public extension OutlierGroup {
    
    // ordered by the list of types below
    var decisionTreeValues: [Double] {
        get async {
            var ret: [Double] = []
            for type in OutlierGroup.TreeDecisionType.allCases {
                ret.append(await self.decisionTreeValue(for: type))
            }
            return ret
        } 
    }

    // the ordering of the list of values above
    static var decisionTreeValueTypes: [OutlierGroup.TreeDecisionType] {
        var ret: [OutlierGroup.TreeDecisionType] = []
        for type in OutlierGroup.TreeDecisionType.allCases {
            ret.append(type)
        }
        return ret
    }

    var decisionTreeGroupValues: OutlierGroupValueMap {
        get async {
            var values = OutlierGroupValueMap()
            for type in OutlierGroup.TreeDecisionType.allCases {
                let value = await self.decisionTreeValue(for: type)
                values.values[type] = value
                //Log.d("frame \(frame_index) type \(type) value \(value)")
            }
            return values
        } 
    }
    
    var shouldPaintFromDecisionTree: Bool {
        get async {
            // XXX have the generator modify this?
            return await self.shouldPaintFromDecisionTree_2db488e9

            // XXX XXX XXX
            // XXX XXX XXX
            // XXX XXX XXX
            // XXX XXX XXX
            //return false        // XXX XXX XX
            // XXX XXX XXX
            // XXX XXX XXX
            // XXX XXX XXX
            // XXX XXX XXX

            //return await self.shouldPaintFromDecisionTree_074081b0
        }
    }
    
    // we derive a Double value from each of these
    // all switches on this enum are in this file
    // add a new case, handle all switches here, and the
    // decision tree generator will use it after recompile
    // all existing outlier value files will need to be regenerated to include itx
    enum TreeDecisionType: CaseIterable, Hashable, Codable, Comparable {
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
        case numberOfNearbyOutliersInSameFrame
        case adjecentFrameNeighboringOutliersBestTheta
        case histogramStreakDetection
        case maxHoughTransformCount
        case maxHoughTheta
        case neighboringInterFrameOutlierThetaScore
        /*
         add score based upon number of close with hough line histogram values
         add score based upon how many overlapping outliers there are in
             adjecent frames, and how close their thetas are 
         
         some more numbers about hough lines

         add some kind of decision based upon other outliers,
         both within this frame, and in others
         
         */

        public var needsAsync: Bool {
            switch self {
            case .numberOfNearbyOutliersInSameFrame:
                return true
            case .adjecentFrameNeighboringOutliersBestTheta:
                return true
            case .histogramStreakDetection:
                return true
            case .neighboringInterFrameOutlierThetaScore:
                return true
            default:
                return false
            }
        }

        private var sortOrder: Int {
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
            case .maxRhoDiffOfFirst10HoughLines:
                return 18
            case .numberOfNearbyOutliersInSameFrame:
                return 19
            case .adjecentFrameNeighboringOutliersBestTheta:
                return 20
            case .histogramStreakDetection:
                return 21
            case .maxHoughTransformCount:
                return 22
            case .maxHoughTheta:
                return 23
            case .neighboringInterFrameOutlierThetaScore:
                return 24
            }
        }

        public static func ==(lhs: TreeDecisionType, rhs: TreeDecisionType) -> Bool {
            return lhs.sortOrder == rhs.sortOrder
        }

        public static func <(lhs: TreeDecisionType, rhs: TreeDecisionType) -> Bool {
            return lhs.sortOrder < rhs.sortOrder
        }        
    }

    func nonAsyncDecisionTreeValue(for type: TreeDecisionType) -> Double {
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
        case .maxHoughTransformCount:
            return self.maxHoughTransformCount
        case .maxHoughTheta:
            return self.maxHoughTheta
        default:
            fatalError("called with bad value \(type)")
        }
    }
    
    func decisionTreeValue(for type: TreeDecisionType) async -> Double {
        switch type {
        case .numberOfNearbyOutliersInSameFrame:
            return await self.numberOfNearbyOutliersInSameFrame
        case .adjecentFrameNeighboringOutliersBestTheta:
            return await self.adjecentFrameNeighboringOutliersBestTheta
        case .histogramStreakDetection:
            return await self.histogramStreakDetection
        case .neighboringInterFrameOutlierThetaScore:
            return await self.neighboringInterFrameOutlierThetaScore
        default:
            return self.nonAsyncDecisionTreeValue(for: type)
        }
    }

    private var maxBrightness: Double {
        var max: UInt32 = 0
        for pixel in pixels {
            if pixel > max { max = pixel }
        }
        return Double(max)
    }
    
    private var medianBrightness: Double {
        var values: [UInt32] = []
        for pixel in pixels {
            if pixel > 0 {
                values.append(pixel)
            }
        }
        return Double(values.sorted()[values.count/2])
    }

    private var numberOfNearbyOutliersInSameFrame: Double {
        get async {
            if let frame = frame {
                let nearby_groups = await frame.outlierGroups(within: 200, // XXX hardcoded constant
                                                              of: self.bounds)
                return Double(nearby_groups.count)
            } else {
                fatalError("SHIT")
            }
        }
    }

    // use these to compare outliers in same and different frames
    var houghLineHistogram: HoughLineHistogram {
        return HoughLineHistogram(withDegreeIncrement: 5, // XXX hardcoded 5
                                  lines: self.lines,
                                  andGroupSize: self.size)
    }

    private var maxHoughTheta: Double {
        if let firstLine = self.firstLine {
            return Double(firstLine.theta)
        }
        return 0
    }
        
    private var maxHoughTransformCount: Double {
        if let firstLine = self.firstLine {
            return Double(firstLine.count)/Double(self.size)
        }
        return 0
    }
    
    // tries to find a streak with hough line histograms
    private var histogramStreakDetection: Double {
        get async {
            if let frame = frame {
                var best_score = 0.0
                let selfHisto = self.houghLineHistogram

                if let previous_frame = await frame.previousFrame {
                    let nearby_groups = await previous_frame.outlierGroups(within: 300, // XXX hardcoded constant
                                                                           of: self.bounds)
                    for group in nearby_groups {
                        let histo = await group.houghLineHistogram
                        let score = histo.matchScore(with: selfHisto)
                        best_score = max(score, best_score)
                    }
                }
                if let next_frame = await frame.nextFrame {
                    let nearby_groups = await next_frame.outlierGroups(within: 300, // XXX hardcoded constant
                                                                           of: self.bounds)
                    for group in nearby_groups {
                        // XXX apply some score to how close this theta
                        // is to the direction it moves in
                        let histo = await group.houghLineHistogram
                        let score = histo.matchScore(with: selfHisto)
                        best_score = max(score, best_score)
                    }
                }
                return best_score
            } else {
                fatalError("SHIT")
            }
        }
    }

    private var neighboringInterFrameOutlierThetaScore: Double {

        get async {
            if let frame = frame {
                let nearby_groups = await frame.outlierGroups(within: 300, // XXX hardcoded constant
                                                              of: self.bounds)
                let selfHisto = self.houghLineHistogram
                var ret = 0.0
                var count = 0
                for group in nearby_groups {
                    if group.name == self.name { continue }
                    let otherHisto = self.houghLineHistogram
                    let score = otherHisto.matchScore(with: selfHisto)
                    // XXX modify this score by how close the theta of
                    // the line between the outlier groups center points
                    // is to the the theta of both of them
                    ret += score
                    count += 1
                }
                if count > 0 { ret /= Double(count) }
                return ret
            }
            return 0
        }
    }
    
    // tries to find the closest theta on any nearby outliers on adjecent frames
    private var adjecentFrameNeighboringOutliersBestTheta: Double {
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
                if let previous_frame = await frame.previousFrame {
                    let nearby_groups = await previous_frame.outlierGroups(within: 200, // XXX hardcoded constant
                                                                           of: self.bounds)
                    for group in nearby_groups {
                        if let firstLine = await group.firstLine {
                            let difference = Double(abs(this_theta - firstLine.theta))
                            if difference < smallest_difference {
                                smallest_difference = difference
                            }
                        }
                    }
                }

                if let next_frame = await frame.nextFrame {
                    let nearby_groups = await next_frame.outlierGroups(within: 200, // XXX hardcoded constant
                                                                       of: self.bounds)
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

    private var maxThetaDiffOfFirst10HoughLines: Double {
        var max_diff = 0.0
        let first_theta = self.lines[0].theta
        for i in 1..<10 {
            let this_theta = self.lines[i].theta
            let this_diff = abs(this_theta - first_theta)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    private var maxRhoDiffOfFirst10HoughLines: Double {
        var max_diff = 0.0
        let first_rho = self.lines[0].rho
        for i in 1..<10 {
            let this_rho = self.lines[i].rho
            let this_diff = abs(this_rho - first_rho)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    private var avgCountOfFirst10HoughLines: Double {
        var sum = 0.0
        var divisor = 0.0
        for i in 0..<10 {
            if i < self.lines.count {
                sum += Double(self.lines[i].count)/Double(self.size)
                divisor += 1
            }
        }
        return sum/divisor
    }

    /*
    func logDecisionTreeValues() {
        var message = "decision tree values for \(self.name): "
        for type in /*OutlierGroup.*/TreeDecisionType.allCases {
            message += "\(type) = \(self.decisionTreeValue(for: type)) " 
        }
        Log.d(message)
    }*/
}
