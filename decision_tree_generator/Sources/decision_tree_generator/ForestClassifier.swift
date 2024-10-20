import Foundation
import StarCore

// a classifier which simulates at runtime what the forest classifier is written to do,
// delegate classification to a set of other weighted classifiers 

struct ForestClassifier: OutlierGroupClassifier {

    let trees: [TreeForestResult]
    
    init(trees: [TreeForestResult]) {
        self.trees = trees
    }

    // returns -1 for negative, +1 for positive
    func asyncClassification(of group: OutlierGroup) async -> Double {
        var ret: Double = 0
        for result in trees {
            ret += await result.tree.asyncClassification(of: group) * result.testScore
        }
        return ret / Double(trees.count)
    }

    // returns -1 for negative, +1 for positive
    func classification(of group: ClassifiableOutlierGroup) -> Double {
        var ret: Double = 0
        for result in trees {
            ret += result.tree.classification(of: group) * result.testScore
        }
        return ret / Double(trees.count)
    }

    // returns -1 for negative, +1 for positive
    func classification (
      of features: [OutlierGroup.Feature],  // parallel
      and values: [Double]                  // arrays
    ) async -> Double
    {
        var ret: Double = 0
        for result in trees {
            ret += await result.tree.classification(of: features, and: values) * result.testScore
        }
        return ret / Double(trees.count)
    }

}

