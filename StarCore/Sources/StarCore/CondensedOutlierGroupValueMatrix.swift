import Foundation

// used for storing only decision tree data for all of the outlier groups in a frame
// this one is used for writing out initial values
public class CondensedOutlierGroupValueMatrix {
    
    public var types: [OutlierGroup.Feature]

    public var outlierValues: [[Double]]
    
    public func append(outlierGroup: OutlierGroup) async {
        outlierValues.append(await outlierGroup.decisionTreeValues())
    }

    public static let typesFilename = "types.csv"
    public static let outlierDataFilename = "outlier_data.csv"

    public init() {
        self.types = OutlierGroup.decisionTreeValueTypes
        self.outlierValues = []
    }

    public func writeCSV(to dir: String) throws {

        // write out types file
        let typesCSV = self.types.map { $0.rawValue }.joined(separator:",").data(using: .utf8)
        let typesCSVFilename = "\(dir)/\(CondensedOutlierGroupValueMatrix.typesFilename)"
        if fileManager.fileExists(atPath: typesCSVFilename) {
            try fileManager.removeItem(atPath: typesCSVFilename)
        }
        fileManager.createFile(atPath: typesCSVFilename,
                                contents: typesCSV,
                                attributes: nil)
        
        var outlierString = ""

        // write out outlier values file
        for values in outlierValues {
            let line = values.map { "\($0)" }.joined(separator: ",")
            outlierString += line
            outlierString += "\n"
        }
        let outlierData = outlierString.data(using: .utf8)
        let outlierFilename = "\(dir)/\(CondensedOutlierGroupValueMatrix.outlierDataFilename)"
        if fileManager.fileExists(atPath: outlierFilename) {
            try fileManager.removeItem(atPath: outlierFilename)
        }
        fileManager.createFile(atPath: outlierFilename,
                               contents: outlierData,
                               attributes: nil)

    }
}



nonisolated(unsafe) fileprivate let fileManager = FileManager.default
