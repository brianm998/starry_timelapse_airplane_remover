import Foundation

// used for storing only decision tree data for all of the outlier groups in a frame
@available(macOS 10.15, *) 
public class OutlierGroupValueMatrix: Codable {
    public var types: [OutlierGroup.Feature] = OutlierGroup.decisionTreeValueTypes

    public struct OutlierGroupValues: Codable {
        public let shouldPaint: Bool
        public let values: [Double]
    }
    
    public var values: [OutlierGroupValues] = []      // indexed by outlier group first then types later
    
    public func append(outlierGroup: OutlierGroup) async {
        if let shouldPaint = outlierGroup.shouldPaint {
            values.append(OutlierGroupValues(shouldPaint: shouldPaint.willPaint,
                                             values: await outlierGroup.decisionTreeValues))
        }
    }
    
    public var outlierGroupValues: ([OutlierFeatureData], [OutlierFeatureData]) {
        var shouldPaintRet: [OutlierFeatureData] = []
        var shoultNotPaintRet: [OutlierFeatureData] = []
        for value in values {
            let groupValues = OutlierFeatureData() { index in 
                return value.values[index]
            }
            if(value.shouldPaint) {
                shouldPaintRet.append(groupValues)
            } else {
                shoultNotPaintRet.append(groupValues)
            }
        }
        return (shouldPaintRet, shoultNotPaintRet)
    }

    public var prettyJson: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        do {
            let data = try encoder.encode(self)
            if let json_string = String(data: data, encoding: .utf8) {
                return json_string
            }
        } catch {
            Log.e("\(error)")
        }
        return nil
    }
}

