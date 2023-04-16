import Foundation

@available(macOS 10.15, *)
public protocol DecisionTree: NamedOutlierGroupClassifier {
    var sha256: String { get }
    var generationSecondsSince1970: TimeInterval { get }
}

