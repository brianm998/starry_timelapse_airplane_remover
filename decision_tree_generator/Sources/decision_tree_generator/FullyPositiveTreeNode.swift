
import Foundation
import StarCore

// end leaf node which always returns 100% positive
struct FullyPositiveTreeNode: SwiftDecisionTree {
    let indent: Int
    var swiftCode: (String, [SwiftDecisionSubtree]) {
        var indentation = ""
        if indent % globalMaxIfDepth == 0 {
            for _ in 0..<initialIndent+(globalMaxIfDepth) { indentation += "    " }
        } else {
            for _ in 0..<initialIndent+(indent%globalMaxIfDepth) { indentation += "    " }
        }
        return ("\(indentation)return 1", [])
    }

    func asyncClassification(of group: OutlierGroup) async -> Double { 1 }
    func classification(of group: ClassifiableOutlierGroup) -> Double { 1 }

    public func classification
      (
        of features: [OutlierGroup.Feature], // parallel
        and values: [Double]                 // arrays
      ) -> Double
    {
        1
    }
}
