/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

/// `@unchecked` because of the lazily-opened `fileHandle` below, which is guarded by
/// `handleLock`. Handlers are called from every thread that logs, so the open-once has to be
/// serialised; the lock is what makes the unchecked conformance honest.
public final class FileLogHandler: LogHandler, @unchecked Sendable {

    let dateFormatter = DateFormatter()
    public let level: Log.Level
    //private let logfilename: String
    public let full_log_path: String
    public let logURL: URL

    /// Held open for the life of the handler rather than reopened per line.
    ///
    /// This used to `FileHandle(forWritingTo:)` / `seekToEndOfFile` / `write` / `closeFile`
    /// for every single line — three extra syscalls each, which was affordable only because
    /// file logging was opt-in and off by default. The gui and daemon now keep a diagnostic
    /// log running for every session, so the per-line cost matters.
    ///
    /// No durability is given up: `FileHandle.write` is an unbuffered `write(2)` either way,
    /// so a line that has been logged is in the page cache whether or not the descriptor is
    /// closed afterwards, and survives the process dying.
    private var fileHandle: FileHandle?
    private let handleLock = NSLock()

    /// - Parameter directory: where the log goes. Defaults to the user's documents directory,
    ///   which is where the cli has always put its `--file-log-level` logs and where users
    ///   have been told to find them. The always-on diagnostic logs pass somewhere less
    ///   intrusive — see `StarCore.DiagnosticLog`.
    public init(at level: Log.Level, in directory: URL? = nil) throws {
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

        let base: URL
        if let directory {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            base = directory
        } else if let documentDirectory = FileManager.default.urls(for: .documentDirectory,
                                                                   in: .userDomainMask).first {
            base = documentDirectory
        } else {
            throw "no full log path"
        }
        logURL = base.appendingPathComponent(logfilename)
        full_log_path = logURL.path

        // this is for log lines
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Delete all but the `keeping` most recent `<prefix>*.txt` files in `directory`.
    ///
    /// An always-on log writes one file per launch and would otherwise grow without bound —
    /// which would be a poor way to repay a session that added a disk-space warning. Sorted
    /// by the modification date rather than by the timestamp in the name, so a file whose name
    /// does not parse is still handled sensibly.
    public static func pruneLogs(in directory: URL, prefix: String, keeping: Int) {
        guard keeping >= 0 else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }

        let logs = contents
          .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "txt" }
          .sorted { lhs, rhs in
              let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
              let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
              return l > r
          }

        for old in logs.dropFirst(keeping) {
            try? FileManager.default.removeItem(at: old)
        }
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

        handleLock.lock()
        defer { handleLock.unlock() }

        if fileHandle == nil {
            if !FileManager.default.fileExists(atPath: full_log_path) {
                _ = FileManager.default.createFile(atPath: full_log_path,
                                                   contents: nil,
                                                   attributes: nil)
            }
            guard let opened = try? FileHandle(forWritingTo: logURL) else { return }
            // Append rather than truncate: the crash handler writes its final line to this
            // same file by path, and a handler opened later must not sit on top of it.
            _ = try? opened.seekToEnd()
            fileHandle = opened
        }

        // Failing to log must never take down a run — a full disk is exactly when logging
        // fails and exactly when the log matters most.
        try? fileHandle?.write(contentsOf: messageData)
    }
}

// make any string into an Error, so it can be thrown by itself if desired
extension String: @retroactive Error {}

