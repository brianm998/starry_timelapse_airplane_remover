
import Foundation

public protocol LogHandler {
    func log(message: String,
             at fileLocation: String,
             with data: LogData?,
             at logLevel: Log.Level)
    
    var dispatchQueue: DispatchQueue { get }
    var level: Log.Level? { get set }
}

