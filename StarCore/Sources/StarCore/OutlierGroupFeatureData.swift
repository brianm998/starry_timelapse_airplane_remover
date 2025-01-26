import Foundation

// a class that holds the data for raw outlier group features for classification
public struct OutlierGroupFeatureData: ClassifiableOutlierGroup,
                                       Sendable
{
    let values: [Double]
    
    public init(features: [OutlierGroupFeature],
                values: [Double])
    {
        var _values = [Double](repeating: 0, count: features.count)
        for (index, type) in features.enumerated() {
            _values[type.sortOrder] = values[index]
        }
        self.values = _values
    }

    public func decisionTreeValueAsync(for type: OutlierGroupFeature) async -> Double  {
        decisionTreeValue(for: type)
    }

    public func decisionTreeValue(for type: OutlierGroupFeature) -> Double  {
        let index = type.sortOrder
        if index >= 0,
           index < values.count
        {
            return values[index]
        } else {
            return 0
        }
    }
}
