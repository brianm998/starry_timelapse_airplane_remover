import Foundation

// a monochrome pixel that is used by the blobber
public struct SortablePixel: AbstractPixel,
                             Hashable,
                             /*@preconcurrency*/ CustomStringConvertible,
                             Codable,
                             Sendable,
                             Identifiable
{
    public let x: Int
    public let y: Int
    public let intensity: UInt16
    
    public init(x: Int = 0,
                y: Int = 0,
                intensity: UInt16 = 0)
    {
        self.x = x
        self.y = y
        self.intensity = intensity
    }

    fileprivate let impossibilyLargeImageWidth = 5000000000000
    public var id: String { "\(y*impossibilyLargeImageWidth+x)" } 
    
    public enum Status: Sendable {
        case unknown
        case background
        case blobbed(Blob)

        public static func != (lhs: SortablePixel.Status, rhs: SortablePixel.Status) -> Bool {
            !(lhs == rhs)
        }
        
        public static func == (lhs: SortablePixel.Status, rhs: SortablePixel.Status) -> Bool {
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

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case intensity
    }
    
    public static func == (lhs: SortablePixel, rhs: SortablePixel) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }

    public var description: String { "[\(x), \(y)]" }


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

     public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(intensity, forKey: .intensity)
    }
}
