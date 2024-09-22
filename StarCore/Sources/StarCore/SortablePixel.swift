import Foundation

public actor StatusPixel: Hashable {

    nonisolated public let _pixel: SortablePixel // XXX rename this
    private var _status = Status.unknown

    public init(_ pixel: SortablePixel) {
        self._pixel = pixel
    }

    public init(x: Int = 0,
                y: Int = 0,
                intensity: UInt16 = 0)
    {
        self._pixel = SortablePixel(x: x, y: y, intensity: intensity)
    }
    
    public func status() -> Status  { _status }
    public func set(status: Status) { _status = status }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(_pixel)
    }
    
    public static func == (lhs: StatusPixel, rhs: StatusPixel) -> Bool {
        return lhs._pixel == rhs._pixel
    }

//    public func pixel() -> SortablePixel  { _pixel } // necessary? 
//    public func set(pixel: SortablePixel) { _pixel = pixel }

    public enum Status: Sendable {
        case unknown
        case background
        case blobbed(Blob)

        public static func != (lhs: StatusPixel.Status, rhs: StatusPixel.Status) -> Bool {
            !(lhs == rhs)
        }
        
        public static func == (lhs: StatusPixel.Status, rhs: StatusPixel.Status) -> Bool {
            switch lhs {
            case .unknown:
                switch rhs {
                case .unknown:
                    return true
                default:
                    return false
                }
            case .background:
                switch rhs {
                case .background:
                    return true
                default:
                    return false
                }
            case .blobbed(let lhsBlob):
                switch rhs {
                case .blobbed(let rhsBlob):
                    return lhsBlob.id == rhsBlob.id
                default:
                    return false
                }
            }
        }
    }
}

// a monochrome pixel that is used by the blobber
public struct SortablePixel: AbstractPixel,
                             Hashable,
                             /*@preconcurrency*/ CustomStringConvertible,
                             Codable,
                             Sendable
{
    public let x: Int
    public let y: Int
    public let intensity: UInt16
    
    enum CodingKeys: String, CodingKey {
        case x
        case y
        case intensity
    }
    
    public static func == (lhs: SortablePixel, rhs: SortablePixel) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }

    public var description: String { "[\(x), \(y)]" }

    public init(x: Int = 0,
                y: Int = 0,
                intensity: UInt16 = 0)
    {
        self.x = x
        self.y = y
        self.intensity = intensity
    }

    /*
      returns percentage that they are similar

         return 0 if they are the same

         return 50 if one value is twice the other
         
         return 100 if one is zero and the other is not
     */
    public func contrast(with otherPixel: SortablePixel) -> Double {
        let diff = Double(abs(Int32(self.intensity) - Int32(otherPixel.intensity)))
        let max = Double(max(self.intensity, otherPixel.intensity))
        
        return diff / max * 100
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Int.self, forKey: .x)
        y = try values.decode(Int.self, forKey: .y)
        intensity = try values.decode(UInt16.self, forKey: .intensity)
    }

    nonisolated public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(intensity, forKey: .intensity)
    }
}
