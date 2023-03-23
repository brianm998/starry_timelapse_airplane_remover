import Foundation

extension String: Error {}

// x, y coordinates
public struct Coord: Codable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

// polar coordinates for right angle intersection with line from origin
public struct Line: Codable {
    public let theta: Double                 // angle in degrees
    public let rho: Double                   // distance in pixels
    public let count: Int                    // higher count is better fit for line
}

public enum Edge {
    case vertical
    case horizontal
}

// a member in an airplane streak across frames
@available(macOS 10.15, *) 
typealias AirplaneStreakMember = (
  frame_index: Int,
  group: OutlierGroup,
  distance: Double?      // the distance from this member to the previous one, nil if first member
)

@available(macOS 10.15, *) 
public actor ThreadSafeArray<Type> {

    private var array: [Type]

    public init() {
        array = []
    }
    
    public init(_ array: [Type]) {
        self.array = array.map { $0 } // copy it
    }
    
    public init(repeating: Type, count: Int) {
        self.array = [Type](repeating: repeating, count: count)
    }

    public func set(atIndex index: Int, to newValue: Type) {
        array[index] = newValue
    }

    public func get(at index: Int) -> Type? {
        if index < 0 { return nil }
        if index >= array.count { return nil }
        return array[index]
    }
    
    public func append(_ value: Type) {
        array.append(value)
    }

    public func sorted() -> ThreadSafeArray<Type> where Type: Comparable {
        return ThreadSafeArray(array.sorted())
    }
    
    public func sorted(_ closure: (Type, Type)->Bool)
      -> ThreadSafeArray<Type> where Type: Comparable
    {
        return ThreadSafeArray(array.sorted(by: closure))
    }
    
    public var count: Int {
        get {
            return array.count
        }
    }
}
