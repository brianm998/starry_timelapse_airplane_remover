
import Foundation
import StarCore

// decision node which decides upon a value of some type
// delegating to one of two further code paths
class DecisionTreeNode: SwiftDecisionTree, @unchecked Sendable {

    public init (type: OutlierGroup.Feature,
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
    let type: OutlierGroup.Feature

    // the value that we are splitting upon
    let value: Double

    // code to handle the case where the input data is less than the given value
    let lessThan: SwiftDecisionTree

    // code to handle the case where the input data is greater than the given value
    let greaterThan: SwiftDecisionTree

    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // runtime execution
    func classification(of group: ClassifiableOutlierGroup) async -> Double {
        let outlierValue = await group.decisionTreeValue(for: type)
        if stump {
            if outlierValue < value {
                return lessThanStumpValue
            } else {
                return greaterThanStumpValue
            }
        } else {
            if outlierValue < value {
                return await lessThan.classification(of: group)
            } else {
                return await greaterThan.classification(of: group)
            }
        }
    }

    func classification
      (
        of features: [OutlierGroup.Feature], // parallel
        and values: [Double]                 // arrays
      ) async -> Double
    {
        for i in 0 ..< features.count {
            if features[i] == type {
                let outlierValue = values[i]

                if stump {
                    if outlierValue < value {
                        return lessThanStumpValue
                    } else {
                        return greaterThanStumpValue
                    }
                } else {
                    if outlierValue < value {
                        return await lessThan.classification(of: features, and: values)
                    } else {
                        return await greaterThan.classification(of: features, and: values)
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
              \(indentation)if await group.decisionTreeValue(for: .\(type)) < \(value) {
              \(indentation)    return \(lessThanStumpValue)
              \(indentation)} else {
              \(indentation)    return \(greaterThanStumpValue)
              \(indentation)}
              """
        } else {
            // recurse on an if statement
            return """
              \(indentation)if await group.decisionTreeValue(for: .\(type)) < \(value) {
              \(lessThan.swiftCode)
              \(indentation)} else {
              \(greaterThan.swiftCode)
              \(indentation)}
              """
        }
    }
}

