import Foundation

// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
public protocol SwiftDecisionTree: OutlierGroupClassifier {
    // returns a string containing swift code that eventually returns a double between -1 and 1
    var swiftCode: (String, [SwiftDecisionSubtree]) { get }
}

public protocol SwiftDecisionSubtree {
    var swiftCode: (String, [SwiftDecisionSubtree]) { get }
}
