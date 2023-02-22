/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

@available(macOS 10.15, *)
public class FileLogHandler: LogHandler {
    
    let dateFormatter = DateFormatter()
    public let dispatchQueue: DispatchQueue
    public var level: Log.Level?
    //private let logfilename: String
    public let full_log_path: String
    public let logURL: URL

    
    public init(at level: Log.Level) throws {
        self.level = level
        // this is for the logfile name
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        var logfilename: String = ""
        if let suffix = Log.nameSuffix {
            logfilename = "\(Log.name)-\(dateString)-\(suffix).txt"
        } else {
            logfilename = "\(Log.name)-\(dateString).txt"
        }
        if let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            logURL = documentDirectory.appendingPathComponent(logfilename)
            full_log_path = logURL.path
        } else {
            throw "no full log path"
        }

        self.dispatchQueue = DispatchQueue(label: "consoleLogging")

        // this is for log lines
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    public func log(message: String,
                    at fileLocation: String,
                    on threadName: String,
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
        let dispatch_group = Log.dispatchGroup
        dispatch_group?.enter()
        dispatchQueue.async {
            let dateString = self.dateFormatter.string(from: Date())
            
            if let data = data {
                self.writeToLogFile("\(dateString) | \(logLevel) | \(threadName) | \(fileLocation): \(message) | \(data.description)\n")
            } else {
                self.writeToLogFile("\(dateString) | \(logLevel) | \(threadName) | \(fileLocation): \(message)\n")
            }
            dispatch_group?.leave()
        }
    }

    private func writeToLogFile(_ message: String) {
        guard let messageData = message.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: full_log_path) {
            guard let fileHandle = try? FileHandle.init(forWritingTo: logURL) else { return }
            fileHandle.seekToEndOfFile()
            fileHandle.write(messageData)
            fileHandle.closeFile()
        } else {
            FileManager.default.createFile(atPath: full_log_path, contents: messageData, attributes: nil)
        }
    }
}
