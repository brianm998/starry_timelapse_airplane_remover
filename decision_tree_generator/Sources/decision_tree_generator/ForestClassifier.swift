import Foundation
import NtarCore

// a classifier which simulates at runtime what the forest classifier is written to do,
// delegate classification to a set of other weighted classifiers 

@available(macOS 10.15, *)
struct ForestClassifier: OutlierGroupClassifier {

    let trees: [TreeForestResult]
    
    init(trees: [TreeForestResult]) {
        self.trees = trees
    }
    // returns -1 for negative, +1 for positive
    func classification(of group: OutlierGroup) async -> Double {
        var ret: Double = 0
        for result in trees {
            ret += await result.tree.classification(of: group) * result.testScore
        }
        return ret / Double(trees.count)
    }

    // returns -1 for negative, +1 for positive
    func classification (
      of types: [OutlierGroup.TreeDecisionType],  // parallel
      and values: [Double]                        // arrays
    ) -> Double
    {
        var ret: Double = 0
        for result in trees {
            ret += result.tree.classification(of: types, and: values) * result.testScore
        }
        return ret / Double(trees.count)
    }

}

