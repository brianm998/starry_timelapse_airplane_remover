import Foundation
import StarCore
import StarDaemonMessages
import logging

/// The daemon's log, changeable while it runs (`Daemon.SetLogLevel`): how much it writes to stderr (which the client keeps in its engine log and
/// shows in its debug window), and an optional log file of its own at another level.
///
/// The two ways of writing are given in, so that what this decides (what a request changes, what a bad one leaves alone) can be tested without
/// touching the process's real handlers.
actor LogControl {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownLevel(String)

        var description: String {
            switch self {
            case .unknownLevel(let level):
                return "unknown log level '\(level)' (use verbose, debug, info, warn or error)"
            }
        }
    }

    struct State: Equatable {
        var level: Log.Level
        var fileEnabled: Bool
        var fileLevel: Log.Level
        /// The file being written, if one is.
        var fileLogPath: String?
    }

    /// What the process's own log is, as `Stard.run` set it up; the one the dispatcher answers for.
    static let shared = LogControl(writeConsole: LogControl.replaceStderrHandler, writeFile: LogControl.replaceFileHandler)

    private(set) var state: State
    private var logsDirectory: URL?
    private let writeConsole: @Sendable (Log.Level) -> Void
    private let writeFile: @Sendable (_ enabled: Bool, _ level: Log.Level, _ directory: URL?) throws -> String?

    init(level: Log.Level = .info,
         writeConsole: @escaping @Sendable (Log.Level) -> Void,
         writeFile: @escaping @Sendable (_ enabled: Bool, _ level: Log.Level, _ directory: URL?) throws -> String?)
    {
        self.state = State(level: level, fileEnabled: false, fileLevel: .info, fileLogPath: nil)
        self.writeConsole = writeConsole
        self.writeFile = writeFile
    }

    /// Take the level the daemon started at, and where its log files go. Nothing is written: the handler is already there at that level.
    func adopt(level: Log.Level, logsDirectory: URL) {
        state.level = level
        self.logsDirectory = logsDirectory
    }

    static func parse(_ text: String) throws -> Log.Level {
        guard let level = Log.Level(rawValue: text.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw Failure.unknownLevel(text)
        }
        return level
    }

    /// Apply a request. An empty `level` or `fileLevel`, or an absent `fileEnabled`, keeps what it was. Everything is read before anything is
    /// changed, and the file (which can fail) is set before the console (which cannot), so a request that cannot be done changes nothing.
    func apply(level: String, fileEnabled: Bool?, fileLevel: String) throws -> State {
        let newLevel = level.isEmpty ? state.level : try Self.parse(level)
        let newFileLevel = fileLevel.isEmpty ? state.fileLevel : try Self.parse(fileLevel)
        let wantFile = fileEnabled ?? state.fileEnabled

        var next = state
        if wantFile != state.fileEnabled || (wantFile && newFileLevel != state.fileLevel) {
            next.fileLogPath = try writeFile(wantFile, newFileLevel, logsDirectory)
            next.fileEnabled = wantFile
        }
        next.fileLevel = newFileLevel
        if newLevel != state.level {
            writeConsole(newLevel)
            next.level = newLevel
        }
        state = next
        return next
    }

    // MARK: - the process's own handlers

    /// Handlers are keyed by where they write, so adding one replaces the one there.
    private static let replaceStderrHandler: @Sendable (Log.Level) -> Void = { level in
        Log.add(handler: StderrLogHandler(at: level), for: .console)
    }

    private static let replaceFileHandler: @Sendable (Bool, Log.Level, URL?) throws -> String? = { enabled, level, directory in
        guard enabled else {
            Log.removeHandler(for: .file)
            return nil
        }
        let handler = try FileLogHandler(at: level, in: directory)
        Log.add(handler: handler, for: .file)
        return handler.full_log_path
    }
}

extension LogControl.State {
    var response: Star_V1_SetLogLevelResponse {
        var response = Star_V1_SetLogLevelResponse()
        response.level = level.rawValue
        response.fileEnabled = fileEnabled
        response.fileLevel = fileLevel.rawValue
        response.fileLogPath = fileLogPath ?? ""
        return response
    }
}
