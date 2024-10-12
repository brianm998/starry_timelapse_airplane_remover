import Foundation

public struct DecisionTreeStruct: DecisionTree {

    public let name: String
    public let sha256: String
    public let swiftCode: String
    public let filename: String
    public let generationSecondsSince1970: TimeInterval
    public let inputSequences: [String]
    public let decisionTypes: [OutlierGroup.Feature]
    public let tree: SwiftDecisionTree
    public var type: ClassifierType
    
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
                type: ClassifierType)
    {
        self.name = name
        self.tree = tree
        self.sha256 = sha256
        self.swiftCode = swiftCode
        self.filename = filename
        self.generationSecondsSince1970 = generationSecondsSince1970
        self.inputSequences = inputSequences
        self.decisionTypes = decisionTypes
        self.type = type
    }

    public func asyncClassification(of group: OutlierGroup) async -> Double {
        await tree.asyncClassification(of: group)
    }
    
    public func classification(of group: ClassifiableOutlierGroup) -> Double {
        tree.classification(of: group)
    }

    // returns -1 for negative, +1 for positive
    public func classification (
      of features: [OutlierGroup.Feature],  // parallel
      and values: [Double]                  // arrays
    ) async -> Double
    {
        await tree.classification(of: features, and: values)
    }
}
