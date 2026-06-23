import Foundation
import logging

/// A log handler that writes to **stderr**.
///
/// `stard`'s stdout carries the binary protobuf frame stream — nothing else may be written there
/// (the LSP rule). The shared `ConsoleLogHandler` uses `print(...)`, which goes to *stdout* and
/// interleaves log text into the frame stream, corrupting it (this manifested as the client
/// desyncing and hanging once logging volume was high enough, e.g. selective clean). The daemon
/// therefore logs through this handler instead.
public final class StderrLogHandler: LogHandler, @unchecked Sendable {
    public let level: Log.Level

    public init(at level: Log.Level) {
        self.level = level
    }

    public func log(
        message: String,
        at fileLocation: String,
        with data: LogData?,
        at logLevel: Log.Level,
        logTime: TimeInterval
    ) {
        let suffix = data.map { " | \($0.description)" } ?? ""
        let line = "\(logLevel) | \(fileLocation): \(message)\(suffix)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
