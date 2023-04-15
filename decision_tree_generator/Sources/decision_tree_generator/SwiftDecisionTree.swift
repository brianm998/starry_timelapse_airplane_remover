
import Foundation
import NtarCore

// end leaf node which always returns 100% positive
@available(macOS 10.15, *) 
struct FullyPositiveTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return 1"
    }

    func classification(of outlierGroup: OutlierGroup) async -> Double {
        return 1
    }

    public func classification
      (
        of types: [OutlierGroup.TreeDecisionType], // parallel
        and values: [Double]                        // arrays
      ) -> Double
    {
        return 1
    }
}

// end leaf node which always returns 100% negative
@available(macOS 10.15, *) 
struct FullyNegativeTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return -1"
    }

    func classification(of outlierGroup: OutlierGroup) async -> Double {
        return -1
    }

    public func classification
      (
        of types: [OutlierGroup.TreeDecisionType], // parallel
        and values: [Double]                        // arrays
      ) -> Double
    {
        return -1
    }
}

// decision node which decides upon a value of some type
// delegating to one of two further code paths
@available(macOS 10.15, *) 
class DecisionTreeNode: SwiftDecisionTree {

    public init (type: OutlierGroup.TreeDecisionType,
                 value: Double,
                 lessThan: SwiftDecisionTree,
                 lessThanStumpValue: Double,
                 greaterThan: SwiftDecisionTree,
                 greaterThanStumpValue: Double,
                 indent: Int,
                 stump: Bool = false)
    {
        self.type = type
        self.value = value
        self.lessThan = lessThan
        self.greaterThan = greaterThan
        self.indent = indent
        self.lessThanStumpValue = lessThanStumpValue
        self.greaterThanStumpValue = greaterThanStumpValue
        self.stump = stump
    }

    // stump means cutting off the tree at this node, and returning stumped values
    // of the test data on either side of the split
    var stump: Bool
    let lessThanStumpValue: Double
    let greaterThanStumpValue: Double
      
    // the kind of value we are deciding upon
    let type: OutlierGroup.TreeDecisionType

    // the value that we are splitting upon
    let value: Double

    // code to handle the case where the input data is less than the given value
    let lessThan: SwiftDecisionTree

    // code to handle the case where the input data is greater than the given value
    let greaterThan: SwiftDecisionTree

    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // runtime execution
    func classification(of outlierGroup: OutlierGroup) async -> Double {
        let outlierValue = await outlierGroup.decisionTreeValue(for: type)
        if stump {
            if outlierValue < value {
                return lessThanStumpValue
            } else {
                return greaterThanStumpValue
            }
        } else {
            if outlierValue < value {
                return await lessThan.classification(of: outlierGroup)
            } else {
                return await greaterThan.classification(of: outlierGroup)
            }
        }
    }

    func classification
      (
        of types: [OutlierGroup.TreeDecisionType], // parallel
        and values: [Double]                        // arrays
      ) -> Double
    {
        for i in 0 ..< types.count {
            if types[i] == type {
                let outlierValue = values[i]

                if stump {
                    if outlierValue < value {
                        return lessThanStumpValue
                    } else {
                        return greaterThanStumpValue
                    }
                } else {
                    if outlierValue < value {
                        return lessThan.classification(of: types, and: values)
                    } else {
                        return greaterThan.classification(of: types, and: values)
                    }
                }
                
            }
        }
        fatalError("cannot find \(type)")
    }
    
    // write swift code to do the same thing
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        if stump {
            return """
              \(indentation)if \(type) < \(value) {
              \(indentation)    return \(lessThanStumpValue)
              \(indentation)} else {
              \(indentation)    return \(greaterThanStumpValue)
              \(indentation)}
              """
        } else {
            // recurse on an if statement
            return """
              \(indentation)if \(type) < \(value) {
              \(lessThan.swiftCode)
              \(indentation)} else {
              \(greaterThan.swiftCode)
              \(indentation)}
              """
        }
    }
}

