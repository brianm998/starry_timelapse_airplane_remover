import Foundation

/// A counting gate whose width can change while threads are parked in it.
///
/// `DispatchSemaphore` cannot be resized, and the GPU entry points are called from native
/// threads inside C++ merges, where an `async` gate is not an option — so this blocks the
/// calling thread, on an `NSCondition`. Raising `max` wakes waiters at once; lowering it
/// lets work already inside finish and admits no one until the count drains below the new
/// width.
public final class BlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var limit: Int
    private var held = 0
    private var parked = 0

    public init(max: Int) {
        limit = Swift.max(1, max)
    }

    /// The current width.
    public var max: Int {
        condition.lock()
        defer { condition.unlock() }
        return limit
    }

    /// Resize. At least 1: a gate of 0 would wedge every caller.
    public func set(max: Int) {
        condition.lock()
        limit = Swift.max(1, max)
        condition.broadcast()
        condition.unlock()
    }

    public func acquire() {
        condition.lock()
        parked += 1
        while held >= limit { condition.wait() }
        parked -= 1
        held += 1
        condition.unlock()
    }

    public func release() {
        condition.lock()
        if held > 0 { held -= 1 }
        condition.broadcast()
        condition.unlock()
    }

    public var inFlight: Int {
        condition.lock()
        defer { condition.unlock() }
        return held
    }

    public var waiting: Int {
        condition.lock()
        defer { condition.unlock() }
        return parked
    }
}
