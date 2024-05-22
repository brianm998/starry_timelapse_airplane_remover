import Foundation
import ArgumentParser
import StarCore

// a utility that takes outlier_data.csv files and categorizes them by paintability
// with a OutlierGroupPaintData.json file
@main
struct Main: AsyncParsableCommand {

    @Option(name: .shortAndLong, help:"""
        The outlier dirname containing a list of numerically named dirs for each frame.
        This utility makes sure that there is a y axis outlier image in each dir that
        has an outliers.tiff
        """)
    var validatedSequenceJsonFilename: String

    mutating func run() async throws {

        /*
         read the validated sequence json filename

         for each sequence

         for each frame

         if we have both OutlierGroupPaintData.json and outlier_data.csv,

         then rm any existing positive_data.csv and negative_data.csv

         for each outlier group in outlier_data.csv,

         determine paintability with json file, and write to existing csv file
         
         */
        
        if fileManager.fileExists(atPath: validatedSequenceJsonFilename) {
            let sequences: [String:[String]] =
              try await read(fromJsonFilename: validatedSequenceJsonFilename)
            for (dirname, dirlist) in sequences {
                for sequence in dirlist {
                    try await process(sequence: "\(dirname)/\(sequence)")
                }
            }
        } else {
            print("no file exists at \(validatedSequenceJsonFilename)")
        }
    }

    func process(sequence dirname: String) async throws {
        print("\(dirname)")

        let outliersDirname = "\(dirname)-outliers"
        let contents = try fileManager.contentsOfDirectory(atPath: outliersDirname)
        for frameIndex in contents {
            let frameOutliersDirname = "\(outliersDirname)/\(frameIndex)"
            try await process(frame: frameOutliersDirname)
        }
    }

    func process(frame dirname: String) async throws {
        print("categorizing feature data in \(dirname)")

        let paintDataJsonFilename = "\(dirname)/\(OutlierGroups.outlierGroupPaintJsonFilename)"
        let outlierDataCSVFilename = "\(dirname)/\(CondensedOutlierGroupValueMatrix.outlierDataFilename)"
        let positiveOutlierDataCSVFilename = "\(dirname)/positive_data.csv"
        let negativeOutlierDataCSVFilename = "\(dirname)/negative_data.csv"

        try await withLimitedThrowingTaskGroup(of: Void.self) { group in
            
            if fileManager.fileExists(atPath: paintDataJsonFilename) {
                let paintReasonMap: [UInt16:PaintReason] =
                  try await read(fromJsonFilename: paintDataJsonFilename)
                if fileManager.fileExists(atPath: outlierDataCSVFilename) {

                    try await group.addTask() {
                        
                        let allCSVData = try await readCSV(from: outlierDataCSVFilename)

                        var positiveRows: [[Double]] = []
                        var negativeRows: [[Double]] = []
                        
                        for csvRow in allCSVData {
                            // here we need to get the outlier id from the first double in the row
                            if let outlierIdDouble = csvRow.first {
                                let outlierFeatureData = Array(csvRow.dropFirst())
                                let outlierId = UInt16(outlierIdDouble)
                                if let paintReason = paintReasonMap[outlierId] {
                                    if paintReason.willPaint {
                                        positiveRows.append(outlierFeatureData)
                                    } else {
                                        negativeRows.append(outlierFeatureData)
                                    }
                                } else {
                                    // XXX gets ignored with no paint reason
                                }
                            }
                        }

                        try writeCSV(positiveRows, to: positiveOutlierDataCSVFilename)
                        try writeCSV(negativeRows, to: negativeOutlierDataCSVFilename)
                    }
                } else {
                    print("cannot proceed: no file exists at \(outlierDataCSVFilename)")
                }
            } else {
                print("cannot proceed: no file exists at \(paintDataJsonFilename)")
            }
            try await group.waitForAll()
        }
    }

    public func writeCSV(_ rows: [[Double]], to filename: String) throws {
        var outlierString = ""

        // write out outlier values file
        for values in rows {
            let line = values.map { "\($0)" }.joined(separator: ",")
            outlierString += line
            outlierString += "\n"
        }
        let outlierData = outlierString.data(using: .utf8)
        if fileManager.fileExists(atPath: filename) {
            try fileManager.removeItem(atPath: filename)
        }
        fileManager.createFile(atPath: filename,
                               contents: outlierData,
                               attributes: nil)
    }
    
    func read<T>(fromJsonFilename filename: String) async throws -> T where T: Decodable {
        let url = NSURL(fileURLWithPath: filename, isDirectory: false) as URL
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func readCSV(from filename: String) async throws -> [[Double]] {
        let url = NSURL(fileURLWithPath: filename, isDirectory: false)

        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url as URL))
        let allTestString = String(decoding: data, as: UTF8.self)
        return allTestString.components(separatedBy: "\n").map { line in
            return line.components(separatedBy: ",").map { NSString(string: $0).doubleValue }
        }
    }
}

fileprivate let fileManager = FileManager.default
