import Foundation

/// Remembers the last value logged under each key, so a line that is rewritten on every
/// `config.update` is logged only when something in it changed.
public final class LogOnChange: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: String] = [:]

    public init() {}

    /// True when `value` differs from the last one recorded under `key` (and records it).
    public func changed(_ key: String, _ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if last[key] == value { return false }
        last[key] = value
        return true
    }

    /// Forget everything, so the next call for every key logs again (a new sequence opened).
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        last.removeAll()
    }

    /// Shared by the config-change blocks: KeypointLimiter, MemoryMonitor, KeypointCache.
    public static let configBlock = LogOnChange()
}
