
import Foundation
import NtarCore


// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
@available(macOS 10.15, *) 
protocol DecisionTree {
    // swift code that eventually returns true or false
    var swiftCode: String { get }
}

// end leaf node which always returns true
@available(macOS 10.15, *) 
struct ReturnTrueTreeNode: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return true"
    }
}

// end leaf node which always returns false
@available(macOS 10.15, *) 
struct ReturnFalseTreeNode: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return false"
    }
}

// decision node which decides upon a value of some type
// delegating to one of two further code paths
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

    // indentention is levels of recursion, not spaces directly
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

