import Foundation

public actor KeypointLimiter {
    private var available: Int
    private var max: Int
    private var waiters: [() -> Void] = []
    
    public init(maxConcurrent: Int) {
        self.available = maxConcurrent
        self.max = maxConcurrent
    }
    
    public func set(maxConcurrent newMax: Int) {
        let diff = newMax - max
        self.available += diff
    }
    
    public func acquire(_ block: @escaping () -> Void) {
        if self.available > 0 {
            self.available -= 1
            block()
        } else {
            self.waiters.append(block)
        }
    }
    
    public func release() {
        if let next = self.waiters.first {
            self.waiters.removeFirst()
            next()
        } else {
            self.available += 1
        }
    }
}
