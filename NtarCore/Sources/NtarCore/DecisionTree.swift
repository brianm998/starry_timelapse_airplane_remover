import Foundation

@available(macOS 10.15, *)
public protocol DecisionTree: NamedOutlierGroupClassifier {
    var name: String { get }
    var sha256: String { get }
    var generationSecondsSince1970: TimeInterval { get }
    var inputSequences: [String] { get }
    var decisionTypes: [OutlierGroup.Feature] { get }
}

