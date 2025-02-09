
import Foundation
import StarCore

// a stumped node, with no further recursion
class StumpedDecisionTreeNode: SwiftDecisionTree, @unchecked Sendable {

    public init (type: OutlierGroupFeature,
                 value: Double,
                 lessThanStumpValue: Double,
                 greaterThanStumpValue: Double,
                 indent: Int,            // really recursion level
                 newMethodLevel: Int)    // how far we recurse before making a new method
                 
    {
        self.type = type
        self.value = value
        self.indent = indent
        self.lessThanStumpValue = lessThanStumpValue
        self.greaterThanStumpValue = greaterThanStumpValue
        self.newMethodLevel = newMethodLevel
    }

    // stump means cutting off the tree at this node, and returning stumped values
    // of the test data on either side of the split
    let lessThanStumpValue: Double
    let greaterThanStumpValue: Double
    
    // the kind of value we are deciding upon
    let type: OutlierGroupFeature

    // the value that we are splitting upon
    let value: Double

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
