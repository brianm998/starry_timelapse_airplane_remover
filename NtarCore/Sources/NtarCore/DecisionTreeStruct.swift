import Foundation

@available(macOS 10.15, *) 
public struct DecisionTreeStruct: DecisionTree {

    public let name: String
    public let sha256: String
    public let swiftCode: String
    public let filename: String
    public let generationSecondsSince1970: TimeInterval
    public let inputSequences: [String]
    public let decisionTypes: [OutlierGroup.Feature]
    public let tree: SwiftDecisionTree
    public let maxDepth: Int?
    public let pruned: Bool
    public var type: ClassifierType {
        return .tree(DecisionTreeParams(name: name,
                                        inputSequences: inputSequences,
                                        decisionTypes: decisionTypes,
                                        maxDepth: maxDepth,
                                        pruned: pruned))
    }
    
    public init() {
        fatalError("don't call this")
    }
    
    public init(name: String,
                swiftCode: String,
                tree: SwiftDecisionTree,
                filename: String,
                sha256: String,
                generationSecondsSince1970: TimeInterval,
                inputSequences: [String],
                decisionTypes: [OutlierGroup.Feature],
                maxDepth: Int?,
                pruned: Bool)
    {
        self.name = name
        self.tree = tree
        self.sha256 = sha256
        self.swiftCode = swiftCode
        self.filename = filename
        self.generationSecondsSince1970 = generationSecondsSince1970
        self.inputSequences = inputSequences
        self.decisionTypes = decisionTypes
        self.maxDepth = maxDepth
        self.pruned = pruned
    }
    
    public func classification(of group: OutlierGroup) async -> Double {
        return await tree.classification(of: group)
    }

    // returns -1 for negative, +1 for positive
    public func classification (
      of features: [OutlierGroup.Feature],  // parallel
      and values: [Double]                        // arrays
    ) -> Double
    {
        return tree.classification(of: features, and: values)
    }
}
