import Foundation

// a monochrome pixel that is used by the blobber
public struct SortablePixel: Hashable,
                             /*@preconcurrency*/ CustomStringConvertible,
                             Sendable,
                             Identifiable
{
    public let x: Int
    public let y: Int
    public let value: ValueType

    public enum ValueType : Sendable {
        case eightBit(UInt8)
        case sixteenBit(UInt16)
        case thirtyTwoBit(Int32)
    }
    
    public init(x: Int = 0,
                y: Int = 0,
                value: ValueType)
    {
        self.x = x
        self.y = y
        self.value = value
    }

    // `static`, not an instance property. As a stored `let` this added 8 bytes to every
    // SortablePixel — and the blobber allocates one per pixel, in
    // FullFrameBlobber.pixels ([[SortablePixel?]]), so at 42MP those 8 bytes cost ~322MB
    // per concurrent blobber to hold a constant used only to build the id string below.
    // Moving it to the type leaves `id` computing exactly the same value.
    fileprivate static let impossibilyLargeImageWidth = 5000000000000
    public var id: String { "\(y*Self.impossibilyLargeImageWidth+x)" }
    
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

    public static func == (lhs: SortablePixel, rhs: SortablePixel) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }

    public var description: String { "[\(x), \(y)]" }

    public var uInt32Value: Int32 {
        switch self.value {
        case .eightBit(let eightBits):
            return Int32(eightBits)
        case .sixteenBit(let sixteenBits):
            return Int32(sixteenBits)
        case .thirtyTwoBit(let thirtyTwoBits):
            return thirtyTwoBits
        }
    }

    public var uInt16Value: UInt16 {
        switch self.value {
        case .eightBit(let eightBits):
            return UInt16(eightBits)
        case .sixteenBit(let sixteenBits):
            return sixteenBits
        case .thirtyTwoBit(_):
            fatalError("cannot convert to 16 bits")
        }
    }

    public var intensity: Double {
        switch self.value {
        case .eightBit(let eightBits):
            return Double(eightBits)/0xFF
        case .sixteenBit(let sixteenBits):
            return Double(sixteenBits)/0xFFFF
        case .thirtyTwoBit(let thirtyTwoBits):
            return Double(thirtyTwoBits)/0xFFFFFFFF
        }
    }

    /*
      returns percentage that they are similar

         return 0 if they are the same

         return 50 if one value is twice the other
         
         return 100 if one is zero and the other is not
     */
    public func contrast(with otherPixel: SortablePixel) -> Double {

        let otherPixelIntensity = otherPixel.uInt32Value
        let selfIntensity = self.uInt32Value
        
        let diff = Double(abs(Int32(selfIntensity) - Int32(otherPixelIntensity)))
        let max = Double(max(selfIntensity, otherPixelIntensity))
        
        return diff / max * 100
    }
}
