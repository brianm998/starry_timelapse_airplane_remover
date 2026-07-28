import Foundation

// Public so the gating behaviour can be exercised directly, alongside MemoryMonitor.
public final class KeypointLimiter: @unchecked Sendable {
    private var max: Int
    private let lock = NSLock()
    private var current = 0

    public init(max: Int) {
        self.max = max
    }

    public func set(max: Int) {
        lock.lock()
        self.max = max
        lock.unlock()
    }

    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if current >= max { return false }
        current += 1
        return true
    }

    /// Wait for a slot, polling until one frees up.
    ///
    /// `tryAcquire` suits an Operation, which can just report itself not-ready and be
    /// polled again. Code already running inside an operation cannot do that — it has to
    /// wait — which is what the homography fallback needs when it finds itself having to
    /// run keypoint detection outside a KeypointOp.
    ///
    /// Bounded, and proceeds with a warning rather than waiting forever, on the same
    /// reasoning as MemoryMonitor's forced admission: slots are only ever held by
    /// KeypointOps, which do finish, so a genuine wait should be short — but hanging the
    /// pipeline would be worse than briefly exceeding the cap.
    public func acquire(timeout: TimeInterval = 300) async -> Bool {
        if tryAcquire() { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if tryAcquire() { return true }
        }
        return false
    }

    public func release() {
        lock.lock()
        if current > 0 { current -= 1 }
        lock.unlock()
    }
}
