// Logging.swift — Bridge C++ logging to Swift logging system
// Re-export kht_bridge so consumers of KHTSwift automatically get all C types
@_exported import kht_bridge
import logging

/// Call this once at startup to route C++ log messages through the Swift logging system.
public func setupKHTLogging() {
    kht_bridge_set_log_handler { message, level, file, function, line in
        guard let message else { return }
        let msg = String(cString: message)
        let lvl = level.flatMap { String(cString: $0) } ?? "info"

        switch lvl {
        case "verbose": Log.v(msg)
        case "debug":   Log.d(msg)
        case "info":    Log.i(msg)
        case "warn":    Log.w(msg)
        case "error":   Log.e(msg)
        default:        Log.i(msg)
        }
    }
}
