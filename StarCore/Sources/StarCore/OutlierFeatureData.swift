import Foundation

// a typed vector of values for a single outlier group
public struct OutlierFeatureData: Sendable {
    // indexed by OutlierGroup.Feature.sortOrder
    public let values: [Double]
    public init(_ values: [Double]) {
        self.values = values
    }
    public static func rawValues() -> [Double] {
        return [Double](repeating: 0.0, count: OutlierGroup.Feature.allCases.count)
    }
    public init(_ closure: (Int) -> Double) {
        var values = OutlierFeatureData.rawValues()
        for i in 0 ..< OutlierGroup.Feature.allCases.count {
            values[i] = closure(i)
        }
        self.values = values
    }
}

