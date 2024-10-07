import Foundation

// a class that holds raw outlier group features for classification
public class OutlierGroupFeatureData: ClassifiableOutlierGroup {
    let values: [Double]
    
    public init(features: [OutlierGroup.Feature],
                values: [Double])

    {
        var _values = [Double](repeating: 0, count: features.count)
        for (index, type) in features.enumerated() {
            _values[type.sortOrder] = values[index]
        }
        self.values = _values
    }

    public func decisionTreeValueAsync(for type: OutlierGroup.Feature) async -> Double {
        decisionTreeValue(for: type)
    }
    
    public func decisionTreeValue(for type: OutlierGroup.Feature) -> Double  {
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
