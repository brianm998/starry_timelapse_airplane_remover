/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/
import Foundation

public class ConsoleLogHandler: LogHandler {

    public let dispatchQueue: DispatchQueue
    public var level: Log.Level?
    private let dateFormatter = DateFormatter()

    public init(at level: Log.Level) {
        self.level = level
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
        self.dispatchQueue = DispatchQueue(label: "fileLogging")
    }
    
    public func log(message: String,
                    at fileLocation: String,
                    on threadName: String,
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
//        dispatchQueue.async {
            let dateString = self.dateFormatter.string(from: Date())
            
            if let data = data {
                print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)")
            } else {
                print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message)")
            }
//        }
    }
}

