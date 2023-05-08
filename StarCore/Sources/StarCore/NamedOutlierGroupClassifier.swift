import Foundation

// a classifier that has a name and can be instantiated
@available(macOS 10.15, *)
public protocol NamedOutlierGroupClassifier: OutlierGroupClassifier {

    init()
    
    var type: ClassifierType { get }
    
    var name: String { get }
}

@available(macOS 10.15, *)
public enum ClassifierType {
    case tree(DecisionTreeParams)
    case forest(DecisionForestParams)
}

@available(macOS 10.15, *)
public struct DecisionTreeParams {

    public init(name: String,
                inputSequences: [String],
                positiveTrainingSize: Int,
                negativeTrainingSize: Int,
                decisionTypes: [OutlierGroup.Feature],
                decisionSplitTypes: [DecisionSplitType],
                maxDepth: Int?,
                pruned: Bool)
    {
        self.name = name
        self.inputSequences = inputSequences
        self.positiveTrainingSize = positiveTrainingSize
        self.negativeTrainingSize = negativeTrainingSize
        self.decisionTypes = decisionTypes
        self.decisionSplitTypes = decisionSplitTypes
        self.maxDepth = maxDepth
        self.pruned = pruned
    }
    
    let name: String
    let inputSequences: [String]
    let positiveTrainingSize: Int
    let negativeTrainingSize: Int
    let decisionTypes: [OutlierGroup.Feature]
    let decisionSplitTypes: [DecisionSplitType]
    let maxDepth: Int?
    let pruned: Bool
}

public struct DecisionForestParams {
    let name: String
    let treeCount: Int
    let treeNames: [String]

    public init(name: String,
                treeCount: Int,
                treeNames: [String])
    {
        self.name = name
        self.treeCount = treeCount
        self.treeNames = treeNames
    }
}

