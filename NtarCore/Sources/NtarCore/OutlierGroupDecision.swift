
/*
 This OutlierGroup extention contains all of the decision tree specific logic.

 Adding a new case to the TreeDecisionType and giving a value for it in decisionTreeValue
 is all needed to add a new value to the decision tree criteria
 
 */

@available(macOS 10.15, *) 
public extension OutlierGroup {
    // we derive a Double value from each of these
    public enum TreeDecisionType: CaseIterable, Hashable {
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
        case brightness
        case avgCountOfFirst10HoughLines
        case maxThetaDiffOfFirst10HoughLines
        case maxRhoDiffOfFirst10HoughLines
        /*
         
         some more numbers about hough lines

         add some kind of decision based upon other outliers,
         both within this frame, and in others
         
         */
    }

    public func decisionTreeValue(for type: TreeDecisionType) -> Double {
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
        case .brightness:
            return Double(self.brightness)
        case .avgCountOfFirst10HoughLines:
            return self.avgCountOfFirst10HoughLines()
        case .maxThetaDiffOfFirst10HoughLines:
            return self.maxThetaDiffOfFirst10HoughLines()
        case .maxRhoDiffOfFirst10HoughLines:
            return self.maxRhoDiffOfFirst10HoughLines()
        }
    }


    func maxThetaDiffOfFirst10HoughLines() -> Double {
        var max_diff = 0.0
        let first_theta = self.lines[0].theta
        for i in 1..<10 {
            let this_theta = self.lines[i].theta
            let this_diff = abs(this_theta - first_theta)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    func maxRhoDiffOfFirst10HoughLines() -> Double {
        var max_diff = 0.0
        let first_rho = self.lines[0].rho
        for i in 1..<10 {
            let this_rho = self.lines[i].rho
            let this_diff = abs(this_rho - first_rho)
            if this_diff > max_diff { max_diff = this_diff }
        }
        return max_diff
    }
    
    func avgCountOfFirst10HoughLines() -> Double {
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
    
    public func logDecisionTreeValues() {
        var message = "decision tree values for \(self.name): "
        for type in /*OutlierGroup.*/TreeDecisionType.allCases {
            message += "\(type) = \(self.decisionTreeValue(for: type)) " 
        }
        Log.d(message)
    }
}