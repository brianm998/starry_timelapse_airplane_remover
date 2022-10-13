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
                    with data: LogData?,
                    at logLevel: Log.Level)
    {
        dispatchQueue.async {
            let dateString = self.dateFormatter.string(from: Date())
            
            if let data = data {
                print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message) | \(data.description)")
            } else {
                print("\(dateString) | \(logLevel.emo) \(logLevel) | \(fileLocation): \(message)")
            }
        }
    }
}

