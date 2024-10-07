import Foundation
import StarCore

final class LinearChoiceTreeNode: SwiftDecisionTree {
    public init (type: OutlierGroup.Feature,
                min: Double,   // returns -1 if input value is equal to min
                max: Double,   // returns +1 if input value is equal to max
                indent: Int)
    {
        self.type = type
        self.min = min
        self.max = max
        self.indent = indent
    }

    // the kind of value we are deciding upon
    let type: OutlierGroup.Feature

    let min: Double

    let max: Double
    
    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // runtime execution
    func classification(of group: ClassifiableOutlierGroup) async -> Double {
        let outlierValue = await group.decisionTreeValueAsync(for: type)

        return (outlierValue - min) / (max - min)*2 - 1;
    }

    func classification
      (
        of features: [OutlierGroup.Feature], // parallel
        and values: [Double]                        // arrays
      ) -> Double
    {
        for i in 0 ..< features.count {
            if features[i] == type {
                let outlierValue = values[i]

                return (outlierValue - min) / (max - min)*2 - 1;
            }

        }
        fatalError("cannot find \(type)")
    }
    
    // write swift code to do the same thing
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return """
          \(indentation)return (await group.decisionTreeValueAsync(for: .\(type)) - \(min)) / (\(max) - \(min)) * 2 - 1
          """
    }
}
