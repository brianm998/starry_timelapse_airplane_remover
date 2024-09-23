import Foundation

public actor ArrayActor<T> {

    public init() { }

    public init(_ array: [T]) {
        self.array = array
    }
    
    private var array: [T] = []

    public func append(_ element: T)  {
        array.append(element)
    }

    public func elements() -> [T] { array }
}
