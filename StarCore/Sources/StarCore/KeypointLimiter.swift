import Foundation

final class KeypointLimiter: @unchecked Sendable {
    private var max: Int
    private let lock = NSLock()
    private var current = 0

    init(max: Int) {
        self.max = max
    }

    func set(max: Int) {
        lock.lock()
        self.max = max
        lock.unlock()
    }

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if current >= max { return false }
        current += 1
        return true
    }

    func release() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
