
import Foundation
import StarCore

// end leaf node which always returns 100% positive
struct FullyPositiveTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return 1"
    }

    func classification(of group: ClassifiableOutlierGroup) -> Double {
        return 1
    }

    public func classification
      (
        of features: [OutlierGroup.Feature], // parallel
        and values: [Double]                 // arrays
      ) -> Double
    {
        return 1
    }
}
