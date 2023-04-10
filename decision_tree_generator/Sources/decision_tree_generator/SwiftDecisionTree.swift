
import Foundation
import NtarCore

// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
@available(macOS 10.15, *) 
protocol SwiftDecisionTree {
    // swift code that eventually returns true or false
    var swiftCode: String { get }

    // XXX get this working
    //func value(for outlierGroup: OutlierGroup) -> Double 
}

// end leaf node which always returns true
@available(macOS 10.15, *) 
struct ReturnTrueTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return 1"
    }
}

// end leaf node which always returns false
@available(macOS 10.15, *) 
struct ReturnFalseTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return -1"
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
                 indent: Int)
    {
        self.type = type
        self.value = value
        self.lessThan = lessThan
        self.greaterThan = greaterThan
        self.indent = indent
        self.lessThanStumpValue = lessThanStumpValue
        self.greaterThanStumpValue = greaterThanStumpValue
    }

    var stump = false
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

