// Logging.swift — Bridge C++ logging to Swift logging system
// Re-export starcpp_bridge so consumers of StarCpp automatically get all C types
@_exported import StarCpp
import logging

/// Call this once at startup to route C++ log messages through the Swift logging system.
public func setupKHTLogging() {
    kht_bridge_set_log_handler { message, level, file, function, line in
        guard let message else { return }
        let msg  = String(cString: message)
        let lvl  = level.flatMap    { String(cString: $0) } ?? "info"
        let fStr = file.flatMap     { String(cString: $0) } ?? "<unknown>"
        let fnStr = function.flatMap { String(cString: $0) } ?? ""
        let lineInt = Int(line)

        switch lvl {
        case "verbose": Log.v(msg, file: fStr, function: fnStr, line: lineInt)
        case "debug":   Log.d(msg, file: fStr, function: fnStr, line: lineInt)
        case "info":    Log.i(msg, file: fStr, function: fnStr, line: lineInt)
        case "warn":    Log.w(msg, file: fStr, function: fnStr, line: lineInt)
        case "error":   Log.e(msg, file: fStr, function: fnStr, line: lineInt)
        default:        Log.i(msg, file: fStr, function: fnStr, line: lineInt)
        }
    }
}
