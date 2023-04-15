import Foundation

@available(macOS 10.15, *)
// a typed vector of values for a single outlier group
public struct OutlierFeatureData {
    // indexed by OutlierGroup.TreeDecisionType.sortOrder
    public let values: [Double]
    public init(_ values: [Double]) {
        self.values = values
    }
    public static func rawValues() -> [Double] {
        return [Double](repeating: 0.0, count: OutlierGroup.TreeDecisionType.allCases.count)
    }
    public init(_ closure: (Int) -> Double) {
        var values = OutlierFeatureData.rawValues()
        for i in 0 ..< OutlierGroup.TreeDecisionType.allCases.count {
            values[i] = closure(i)
        }
        self.values = values
    }
}

