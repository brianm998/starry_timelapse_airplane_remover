import Foundation

// used for storing only decision tree data for all of the outlier groups in a frame
public class OutlierGroupValueMatrix {
    
    public var types: [OutlierGroup.Feature]

    public var positiveValues: [[Double]]
    public var negativeValues: [[Double]]
    
    public func append(outlierGroup: OutlierGroup) async {
        if let shouldPaint = outlierGroup.shouldPaint {
            let values = outlierGroup.decisionTreeValues
            if shouldPaint.willPaint {
                positiveValues.append(values)
            } else {
                negativeValues.append(values)
            }
        }
    }

    public static var typesFilename = "types.csv"
    public static var positiveDataFilename = "positive_data.csv"
    public static var negativeDataFilename = "negative_data.csv"

    public init() {
        self.types = OutlierGroup.decisionTreeValueTypes
        self.positiveValues = []
        self.negativeValues = []
    }
    
    public init?(from dir: String) async throws {
        let typesCSVFilename = "\(dir)/\(OutlierGroupValueMatrix.typesFilename)"
        if fileManager.fileExists(atPath: typesCSVFilename) {

            let url = NSURL(fileURLWithPath: typesCSVFilename,
                            isDirectory: false)

            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
            let csv_string = String(decoding: data, as: UTF8.self)
            self.types = csv_string.components(separatedBy: ",").map { OutlierGroup.Feature(rawValue: $0)! }
        } else {
            return nil
        }

        let positive_filename = "\(dir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
        if fileManager.fileExists(atPath: positive_filename) {

            let url = NSURL(fileURLWithPath: positive_filename,
                            isDirectory: false)

            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
            let positive_string = String(decoding: data, as: UTF8.self)
            var values = positive_string.components(separatedBy: "\n").map { line in
                return line.components(separatedBy: ",").map { NSString(string: $0).doubleValue }
            }
            // a trailing newline can cause a bad entry at the very end
            if values[values.count-1].count != self.types.count {
                values.removeLast()
            }
            self.positiveValues = values
        } else {
            return nil
        }

        let negative_filename = "\(dir)/\(OutlierGroupValueMatrix.negativeDataFilename)"
        if fileManager.fileExists(atPath: negative_filename) {

            let url = NSURL(fileURLWithPath: negative_filename,
                            isDirectory: false)

            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
            let negative_string = String(decoding: data, as: UTF8.self)


            var values = negative_string.components(separatedBy: "\n").map { line in
                line.components(separatedBy: ",").map { NSString(string: $0).doubleValue }
            }
            // a trailing newline can cause a bad entry at the very end
            if values[values.count-1].count != self.types.count {
                values.removeLast()
            }
            self.negativeValues = values
            
        } else {
            return nil
        }
    }

    public func writeCSV(to dir: String) throws {

        // write out types file
        let typesCSV = self.types.map { $0.rawValue }.joined(separator:",").data(using: .utf8)
        let typesCSVFilename = "\(dir)/\(OutlierGroupValueMatrix.typesFilename)"
        if fileManager.fileExists(atPath: typesCSVFilename) {
            try fileManager.removeItem(atPath: typesCSVFilename)
        }
        fileManager.createFile(atPath: typesCSVFilename,
                                contents: typesCSV,
                                attributes: nil)
        
        var positiveString = ""

        // write out positive values file
        for values in positiveValues {
            let line = values.map { "\($0)" }.joined(separator: ",")
            positiveString += line
            positiveString += "\n"
        }
        let positiveData = positiveString.data(using: .utf8)
        let positiveFilename = "\(dir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
        if fileManager.fileExists(atPath: positiveFilename) {
            try fileManager.removeItem(atPath: positiveFilename)
        }
        fileManager.createFile(atPath: positiveFilename,
                             contents: positiveData,
                             attributes: nil)

        // write out negative values file
        var negativeString = ""

        for values in negativeValues {
            let line = values.map { "\($0)" }.joined(separator: ",")
            negativeString += line
            negativeString += "\n"
        }
        let negativeData = negativeString.data(using: .utf8)
        let negativeFilename = "\(dir)/\(OutlierGroupValueMatrix.negativeDataFilename)"
        if fileManager.fileExists(atPath: negativeFilename) {
            try fileManager.removeItem(atPath: negativeFilename)
        }
        fileManager.createFile(atPath: negativeFilename,
                                contents: negativeData,
                                attributes: nil)
    }
}



fileprivate let fileManager = FileManager.default
