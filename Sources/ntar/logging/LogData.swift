
import Foundation

public protocol LogData: CustomStringConvertible {
    // we _might_ have an encodable, but we ^^^ always have a description string
    var encodable: Encodable? { get }
}


