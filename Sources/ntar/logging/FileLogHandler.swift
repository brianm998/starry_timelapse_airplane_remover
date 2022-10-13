
import Foundation

public class FileLogHandler: LogHandler {
    
    let dateFormatter = DateFormatter()
    public let dispatchQueue: DispatchQueue
    public var level: Log.Level?
    private let logfilename: String

    public init(at level: Log.Level) {
        self.level = level
        // this is for the logfile name
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        self.logfilename = "log-\(dateString).txt"
        self.dispatchQueue = DispatchQueue(label: "consoleLogging")

        // this is for log lines
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    public func log(message: String,
                    at fileLocation: String,
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
        dispatchQueue.async {
            let dateString = self.dateFormatter.string(from: Date())
            
            if let data = data {
                self.writeToLogFile("\(dateString) | \(logLevel) | \(fileLocation): \(message) | \(data.description)\n")
            } else {
                self.writeToLogFile("\(dateString) | \(logLevel) | \(fileLocation): \(message)\n")
            }
        }
    }

    private func writeToLogFile(_ message: String) {
        guard let messageData = message.data(using: .utf8) else { return }
        if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {

            let logURL = documentDirectory.appendingPathComponent(logfilename)
            if FileManager.default.fileExists(atPath: logURL.path) {
                guard let fileHandle = try? FileHandle.init(forWritingTo: logURL) else { return }
                fileHandle.seekToEndOfFile()
                fileHandle.write(messageData)
                fileHandle.closeFile()
            } else {
                FileManager.default.createFile(atPath: logURL.path, contents: messageData, attributes: nil)
            }
        }
    }
}
