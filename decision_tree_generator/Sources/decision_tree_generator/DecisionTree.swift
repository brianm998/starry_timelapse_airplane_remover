
import Foundation
import NtarCore


// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
@available(macOS 10.15, *) 
protocol DecisionTree {
    // output swift code eventually returns true or false
    var swiftCode: String { get }
}

// end leaf node which always returns true
@available(macOS 10.15, *) 
struct ShouldPaintDecision: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return true"
    }
}

// end leaf node which always returns false
@available(macOS 10.15, *) 
struct ShouldNotPaintDecision: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return false"
    }
}

// intermediate node which decides based upon the value of a particular type
@available(macOS 10.15, *) 
struct DecisionTreeNode: DecisionTree {

    // the kind of value we are deciding upon
    let type: OutlierGroup.TreeDecisionType

    // the value that we are splitting upon
    let value: Double

    // code to handle the case where the input data is less than the given value
    let lessThan: DecisionTree

    // code to handle the case where the input data is greater than the given value
    let greaterThan: DecisionTree

    // indentention is levels of recursion, not directly spaces
    let indent: Int

    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return """
          \(indentation)if \(type) < \(value) {
          \(lessThan.swiftCode)
          \(indentation)} else {
          \(greaterThan.swiftCode)
          \(indentation)}
          """
    }
}

