import Foundation

// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
@available(macOS 10.15, *) 
public protocol SwiftDecisionTree: OutlierGroupClassifier {
    // returns a string containing swift code that eventually returns a double between -1 and 1
    var swiftCode: String { get }
}

