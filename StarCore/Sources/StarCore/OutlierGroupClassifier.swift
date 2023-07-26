
import Foundation

// describes an object able to classify an OutlierGroup
// (or just its feature vector) to a value of -1 (not paintable)
// to a value of 1 (paintable).  0 is unknown, any other value
// gives the possibility of the result, with +1 and -1 being 100% sure.
public protocol OutlierGroupClassifier {

    // returns -1 for negative, +1 for positive
    func classification(of group: ClassifiableOutlierGroup) -> Double

    // returns -1 for negative, +1 for positive
    func classification (
      of features: [OutlierGroup.Feature],        // parallel
      and values: [Double]                        // arrays
    ) -> Double
}

