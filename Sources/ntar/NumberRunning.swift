import Foundation

@available(macOS 10.15, *)
actor NumberRunning {
    private var count: UInt = 0

    public func increment() {
        count = count + 1 
    }

    public func decrement() {
        count = count - 1 
    }

    public func currentValue() -> UInt {
        return count
    }
}

