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
            return await self.shouldPaintFromDecisionTree_fdcf1329

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
    enum TreeDecisionType: CaseIterable, Hashable, Codable {
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
        /*
         
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
            default:
                return false
            }
        }
    }

    func nonAsyncDecisionTreeValue(for type: TreeDecisionType) -> Double {
        switch type {
        case .size:
            return Double(self.size)
        case .width:
            return Double(self.bounds.width)
        case .height:
            return Double(self.bounds.height)
        case .centerX:
            return Double(self.bounds.center.x)/IMAGE_WIDTH!
        case .minX:
            return Double(self.bounds.min.x)/IMAGE_WIDTH!
        case .maxX:
            return Double(self.bounds.max.x)/IMAGE_WIDTH!
        case .minY:
            return Double(self.bounds.min.y)/IMAGE_HEIGHT!
        case .maxY:
            return Double(self.bounds.max.y)/IMAGE_HEIGHT!
        case .centerY:
            return Double(self.bounds.center.y)/IMAGE_HEIGHT!
        case .hypotenuse:
            return Double(self.bounds.hypotenuse)/(IMAGE_HEIGHT!*IMAGE_WIDTH!)
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
        var max: UInt32 = 0
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
                let ret: Double = 0
                let nearby_groups = await frame.outlierGroups(within: 200, // XXX hardcoded constant
                                                              of: self.bounds)
                return Double(nearby_groups.count)
            } else {
                fatalError("SHIT")
            }
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
                let ret: Double = 0
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
