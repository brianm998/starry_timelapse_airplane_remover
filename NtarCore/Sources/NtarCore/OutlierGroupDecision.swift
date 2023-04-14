import Foundation

/*
 This OutlierGroup extention contains all of the decision tree specific logic.

 Adding a new case to the TreeDecisionType and giving a value for it in decisionTreeValue
 is all needed to add a new value to the decision tree criteria
 
 */

// different ways we split up data sets that are still overlapping
public enum DecisionSplitType: String {
    case median
    case mean
    // XXX others ???
}

@available(macOS 10.15, *)
// a typed vector of values for a single outlier group
public struct OutlierGroupValueMap {
    // indexed by OutlierGroup.TreeDecisionType.sortOrder
    public let values: [Double]
    public init(_ values: [Double]) {
        self.values = values
    }
    public static func rawValues() -> [Double] {
        return [Double](repeating: 0.0, count: OutlierGroup.TreeDecisionType.allCases.count)
    }
    public init(_ closure: (Int) -> Double) {
        var values = OutlierGroupValueMap.rawValues()
        for i in 0 ..< OutlierGroup.TreeDecisionType.allCases.count {
            values[i] = closure(i)
        }
        self.values = values
    }
}

// a list of all extant decision trees at runtime, indexed by hash prefix
@available(macOS 10.15, *)
// XXX we need an actor here for thread safety
public var decisionTrees: [String: DecisionTree] = loadDecisionTrees()

@available(macOS 10.15, *)
public func loadDecisionTrees() -> [String : DecisionTree] {
    let decisionTrees = listClasses { $0.compactMap { $0 as? DecisionTree.Type } }
    var ret: [String: DecisionTree] = [:]
    for tree in decisionTrees {
        let instance = tree.init()
        ret[instance.name] = instance
    }
    Log.i("loaded \(ret.count) decision trees")
    return ret
}

// black magic from the objc runtime
fileprivate func listClasses<T>(_ body: (UnsafeBufferPointer<AnyClass>) throws -> T) rethrows -> T {
  var cnt: UInt32 = 0
  let ptr = objc_copyClassList(&cnt)
  defer { free(UnsafeMutableRawPointer(ptr)) }
  let buf = UnsafeBufferPointer( start: ptr, count: Int(cnt) )
  return try body(buf)
}


@available(macOS 10.15, *)
public protocol DecisionTree: OutlierGroupClassifier {
    init()
    var name: String { get }
    var sha256: String { get }
    var generationSecondsSince1970: TimeInterval { get }
    var inputSequences: [String] { get }
    var decisionTypes: [OutlierGroup.TreeDecisionType] { get }
}

// describes an object able to classify an OutlierGroup
// (or just its feature vector) to a value of -1 (not paintable)
// to a value of 1 (paintable).  0 is unknown, any other value
// gives the possibility of the result, with +1 and -1 being 100% sure.
@available(macOS 10.15, *)
public protocol OutlierGroupClassifier {
    
    // returns -1 for negative, +1 for positive
    func classification(of group: OutlierGroup) async -> Double

    // returns -1 for negative, +1 for positive
    func classification (
      of types: [OutlierGroup.TreeDecisionType],  // parallel
      and values: [Double]                        // arrays
    ) -> Double
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

    var maxTheta: Double {
        var max_value: Double = 0
        var max_index: Int = 0

        for (index, value) in values.enumerated() {
            if value > max_value {
                max_value = value
                max_index = index
            }
        }
        var ret = Double(max_index*increment)
        if ret > 360 { ret -= 360 }
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
        get async {
            var shouldPaintRet: [OutlierGroupValueMap] = []
            var shoultNotPaintRet: [OutlierGroupValueMap] = []
            for value in values {
                let groupValues = OutlierGroupValueMap() { index in 
                    return value.values[index]
                }
                if(value.shouldPaint) {
                    shouldPaintRet.append(groupValues)
                } else {
                    shoultNotPaintRet.append(groupValues)
                }
            }
            return (shouldPaintRet, shoultNotPaintRet)
        }
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
            var rawValues = OutlierGroupValueMap.rawValues()
            for type in OutlierGroup.TreeDecisionType.allCases {
                let value = await self.decisionTreeValue(for: type)
                rawValues[type.sortOrder] = value
                //Log.d("frame \(frame_index) type \(type) value \(value)")
            }
            return OutlierGroupValueMap(rawValues)
        } 
    }
    
    // we derive a Double value from each of these
    // all switches on this enum are in this file
    // add a new case, handle all switches here, and the
    // decision tree generator will use it after recompile
    // all existing outlier value files will need to be regenerated to include itx
    enum TreeDecisionType: String,
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
            for type in OutlierGroup.TreeDecisionType.allCases {
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
            case .maxHoughTransformCount:
                return 25
            case .maxHoughTheta:
                return 26
            case .neighboringInterFrameOutlierThetaScore:
                return 27
            case .maxOverlap:
                return 28
            case .maxOverlapTimesThetaHisto:
                return 29
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
        case .maxOverlap:
            return await self.maxOverlap
        case .maxOverlapTimesThetaHisto:
            return await self.maxOverlapTimesThetaHisto
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

    private var maxNearbyGroupDistance: Double {
        800*7000/IMAGE_WIDTH! // XXX hardcoded constant
    }

    // returns 1 if they are the same
    // returns 0 if they are 180 degrees apart
    private func thetaScore(between theta_1: Double, and theta_2: Double) -> Double {

        var theta_1_opposite = theta_1 + 180
        if theta_1_opposite > 360 { theta_1_opposite -= 360 }

        var opposite_difference = theta_1_opposite - theta_2

        if opposite_difference <   0 { opposite_difference += 360 }
        if opposite_difference > 360 { opposite_difference -= 360 }

        return opposite_difference / 180.0
    }
    
    // tries to find a streak with hough line histograms
    private var histogramStreakDetection: Double {
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
    private func thetaHistoCenterLineScore(with group: OutlierGroup,
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
    private var histogramStreakDetectionV2: Double { // XXX rename this
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

    private var maxOverlap: Double {
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

    private var maxOverlapTimesThetaHisto: Double {
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
    
    private var neighboringInterFrameOutlierThetaScore: Double {
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

    private var maxThetaDiffOfFirst10HoughLines: Double {
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
    
    private var maxRhoDiffOfFirst10HoughLines: Double {
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
    
    private var avgCountOfFirst10HoughLines: Double {
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

    private var maxThetaDiffOfAllHoughLines: Double {
        var max_diff = 0.0
        let first_theta = self.lines[0].theta
        for i in 1..<self.lines.count {
            let this_theta = self.lines[i].theta
            let this_diff = abs(this_theta - first_theta)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    private var maxRhoDiffOfAllHoughLines: Double {
        var max_diff = 0.0
        let first_rho = self.lines[0].rho
        for i in 1..<self.lines.count {
            let this_rho = self.lines[i].rho
            let this_diff = abs(this_rho - first_rho)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    private var avgCountOfAllHoughLines: Double {
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
        for type in /*OutlierGroup.*/TreeDecisionType.allCases {
            message += "\(type) = \(self.decisionTreeValue(for: type)) " 
        }
        Log.d(message)
    }*/
}
