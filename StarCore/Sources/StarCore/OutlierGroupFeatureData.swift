import Foundation

// a class that holds raw outlier group features for classification
public class OutlierGroupFeatureData: ClassifiableOutlierGroup {
    let map: [OutlierGroup.Feature:Double]

    public init(features: [OutlierGroup.Feature],
                values: [Double])

    {
        var _map: [OutlierGroup.Feature:Double] = [:]
        for (index, type) in features.enumerated() {
            let value = values[index]
            _map[type] = value
        }
        self.map = _map
    }

    public func decisionTreeValue(for type: OutlierGroup.Feature) -> Double  {
        if let ret = map[type] {
            return ret 
        } else {
            fatalError("no decision tree value for type \(type)")
        }
    }
}
