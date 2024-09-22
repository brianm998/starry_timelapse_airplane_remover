/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

public final class FileLogHandler: LogHandler {
    
    let dateFormatter = DateFormatter()
    public let level: Log.Level
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

        // this is for log lines
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    public func log(message: String,
                    at fileLocation: String,
                    with data: LogData?,
                    at logLevel: Log.Level,
                    logTime: TimeInterval)
    {
        let date = Date(timeIntervalSinceReferenceDate: logTime)
        let dateString = self.dateFormatter.string(from: date)
        
        if let data = data {
            self.writeToLogFile("\(dateString) | \(logLevel) | \(fileLocation): \(message) | \(data.description)\n")
        } else {
            self.writeToLogFile("\(dateString) | \(logLevel) | \(fileLocation): \(message)\n")
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

// make any string into an Error, so it can be thrown by itself if desired
extension String: @retroactive Error {}

