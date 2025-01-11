import Foundation

public actor IntegralActor {
    var value: Int

    public init(value: Int) {
        self.value = value
    }

    public func getValue() -> Int { value }

    public func set(value: Int) {
        self.value = value
    }
}

