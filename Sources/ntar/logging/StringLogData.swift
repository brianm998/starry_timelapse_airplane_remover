import Foundation

public struct StringLogData: LogData {

    public let encodable: Encodable? = nil
    public let description: String

    public init(with convertable: CustomStringConvertible) {
        self.description = convertable.description
    }

    public init(with string: String) {
        self.description = string
    }

    public init<T>(with data: T) {
        self.description = String(describing: data)
    }
}

