
import Foundation
import StarCore

// a stumped node, with no further recursion
class StumpedDecisionTreeNode: SwiftDecisionTree, @unchecked Sendable {

    public init (result: DecisionResult,
                 indent: Int,            // really recursion level
                 newMethodLevel: Int)    // how far we recurse before making a new method
                 
    {
        self.result = result
        self.type = result.type
        self.value = result.value
        self.indent = indent
        self.newMethodLevel = newMethodLevel

        let lessThanPaintCount = result.lessThanPositive.count
        let lessThanNotPaintCount = result.lessThanNegative.count
        
        let greaterThanPaintCount = result.greaterThanPositive.count
        let greaterThanNotPaintCount = result.greaterThanNegative.count
        
        let paintMax = Double(lessThanPaintCount+greaterThanPaintCount)
        let notPaintMax = Double(lessThanNotPaintCount+greaterThanNotPaintCount)
        
        // divide by max to even out 1/10 disparity in true/false data
        let lessThanPaintDiv = Double(lessThanPaintCount)/paintMax
        let greaterThanPaintDiv = Double(greaterThanPaintCount)/paintMax

        self.lessThanStumpValue = lessThanPaintDiv / (lessThanPaintDiv + Double(lessThanNotPaintCount)/notPaintMax) * 2 - 1
        
        //Log.i("lessThanPaintCount \(lessThanPaintCount) lessThanNotPaintCount \(lessThanNotPaintCount) lessThanStumpValue \(lessThanStumpValue)")
        
        
        self.greaterThanStumpValue = greaterThanPaintDiv / (greaterThanPaintDiv + Double(greaterThanNotPaintCount)/notPaintMax) * 2 - 1
        
        //Log.i("greaterThanPaintCount \(greaterThanPaintCount) greaterThanNotPaintCount \(greaterThanNotPaintCount) greaterThanStumpValue \(greaterThanStumpValue)")
        
    }

    // stump means cutting off the tree at this node, and returning stumped values
    // of the test data on either side of the split
    let lessThanStumpValue: Double
    let greaterThanStumpValue: Double
    
    // the kind of value we are deciding upon
    let type: OutlierGroupFeature

    // the value that we are splitting upon
    let value: Double

    let result: DecisionResult
    
    var valueString: String {
        "\(value)"
          .replacingOccurrences(of: ".", with: "_")
          .replacingOccurrences(of: "-", with: "_")
    }
    
    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // how far do we recurse before starting a new method?
    let newMethodLevel: Int
    
    // runtime execution

    func classification(of group: ClassifiableOutlierGroup) async -> Double {
        let outlierValue = group.decisionTreeValue(for: type)

        if outlierValue < value {
            return lessThanStumpValue
        } else {
            return greaterThanStumpValue
        }

    }

    func classification
      (
        of features: [OutlierGroupFeature], // parallel
        and values: [Double]                 // arrays
      ) async -> Double
    {
        for i in 0 ..< features.count {
            if features[i] == type {
                let outlierValue = values[i]

                if outlierValue < value {
                    return lessThanStumpValue
                } else {
                    return greaterThanStumpValue
                }
            }
        }
        fatalError("cannot find \(type)")
    }

    // write swift code to do the same thing
    var swiftCode: (String, [SwiftDecisionSubtree]) {
        var indentation = ""
        for _ in 0..<initialIndent+(indent % newMethodLevel) { indentation += "    " }

        var methodCallString = "group.decisionTreeValue"
        
        if type.isAsync {
            methodCallString = "await group.decisionTreeValueAsync"
        }
        
        let swift = """
          \(indentation)if \(methodCallString)(for: .\(type)) < \(value) {
          \(indentation)    return \(lessThanStumpValue)
          \(indentation)} else {
          \(indentation)    return \(greaterThanStumpValue)
          \(indentation)}
          """
        return (swift, [])
    }
}
