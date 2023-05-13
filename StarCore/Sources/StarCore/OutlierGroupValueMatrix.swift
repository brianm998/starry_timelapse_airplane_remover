import Foundation

// used for storing only decision tree data for all of the outlier groups in a frame
public class OutlierGroupValueMatrix {
    
    public var types: [OutlierGroup.Feature]

    public var positiveValues: [[Double]]
    public var negativeValues: [[Double]]
    
    public func append(outlierGroup: OutlierGroup) async {
        if let shouldPaint = outlierGroup.shouldPaint {
            let values = await outlierGroup.decisionTreeValues
            if shouldPaint.willPaint {
                positiveValues.append(values)
            } else {
                negativeValues.append(values)
            }
        }
    }

    public static var types_filename = "types.csv"
    public static var positive_data_filename = "positive_data.csv"
    public static var negative_data_filename = "negative_data.csv"

    public init() {
        self.types = OutlierGroup.decisionTreeValueTypes
        self.positiveValues = []
        self.negativeValues = []
    }
    
    public init?(from dir: String) async throws {
        let types_csv_filename = "\(dir)/\(OutlierGroupValueMatrix.types_filename)"
        if file_manager.fileExists(atPath: types_csv_filename) {

            let url = NSURL(fileURLWithPath: types_csv_filename,
                            isDirectory: false)

            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
            let csv_string = String(decoding: data, as: UTF8.self)
            self.types = csv_string.components(separatedBy: ",").map { OutlierGroup.Feature(rawValue: $0)! }
        } else {
            return nil
        }

        let positive_filename = "\(dir)/\(OutlierGroupValueMatrix.positive_data_filename)"
        if file_manager.fileExists(atPath: positive_filename) {

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

        let negative_filename = "\(dir)/\(OutlierGroupValueMatrix.negative_data_filename)"
        if file_manager.fileExists(atPath: negative_filename) {

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
        let types_csv = self.types.map { $0.rawValue }.joined(separator:",").data(using: .utf8)
        let types_csv_filename = "\(dir)/\(OutlierGroupValueMatrix.types_filename)"
        if file_manager.fileExists(atPath: types_csv_filename) {
            try file_manager.removeItem(atPath: types_csv_filename)
        }
        file_manager.createFile(atPath: types_csv_filename,
                                contents: types_csv,
                                attributes: nil)
        
        var positive_string = ""

        // write out positive values file
        for values in positiveValues {
            let line = values.map { "\($0)" }.joined(separator: ",")
            positive_string += line
            positive_string += "\n"
        }
        let positive_data = positive_string.data(using: .utf8)
        let positive_filename = "\(dir)/\(OutlierGroupValueMatrix.positive_data_filename)"
        if file_manager.fileExists(atPath: positive_filename) {
            try file_manager.removeItem(atPath: positive_filename)
        }
        file_manager.createFile(atPath: positive_filename,
                                contents: positive_data,
                                attributes: nil)

        // write out negative values file
        var negative_string = ""

        for values in negativeValues {
            let line = values.map { "\($0)" }.joined(separator: ",")
            negative_string += line
            negative_string += "\n"
        }
        let negative_data = negative_string.data(using: .utf8)
        let negative_filename = "\(dir)/\(OutlierGroupValueMatrix.negative_data_filename)"
        if file_manager.fileExists(atPath: negative_filename) {
            try file_manager.removeItem(atPath: negative_filename)
        }
        file_manager.createFile(atPath: negative_filename,
                                contents: negative_data,
                                attributes: nil)
    }
}



fileprivate let file_manager = FileManager.default
