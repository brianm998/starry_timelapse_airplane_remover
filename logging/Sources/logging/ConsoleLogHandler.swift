/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/
import Foundation

public final class ConsoleLogHandler: LogHandler {

    public let dispatchQueue: DispatchQueue
    public let level: Log.Level
    private let dateFormatter = DateFormatter()

    public init(at level: Log.Level) {
        self.level = level
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
        self.dispatchQueue = DispatchQueue(label: "fileLogging")
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
            print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)")
        } else {
            print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message)")
        }
    }
}

