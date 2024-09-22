import Foundation

// used for storing only decision tree data for all of the outlier groups in a frame
// this one is used for reading condensed and categorized data
public class OutlierGroupValueMatrix {
    
    public var types: [OutlierGroup.Feature]

    public var positiveValues: [[Double]]
    public var negativeValues: [[Double]]

    public static let positiveDataFilename = "positive_data.csv"
    public static let negativeDataFilename = "negative_data.csv"

    public init?(from dir: String) async throws {
        let typesCSVFilename = "\(dir)/\(CondensedOutlierGroupValueMatrix.typesFilename)"
        if FileManager.default.fileExists(atPath: typesCSVFilename) {

            let url = NSURL(fileURLWithPath: typesCSVFilename,
                            isDirectory: false)

            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
            let csv_string = String(decoding: data, as: UTF8.self)
            self.types = csv_string.components(separatedBy: ",").map { OutlierGroup.Feature(rawValue: $0)! }
        } else {
            return nil
        }

        let positive_filename = "\(dir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
        if FileManager.default.fileExists(atPath: positive_filename) {

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
        if FileManager.default.fileExists(atPath: negative_filename) {

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
}



