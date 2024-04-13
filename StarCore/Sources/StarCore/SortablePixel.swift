import Foundation

// a monochrome pixel that is used by the blobber
public class SortablePixel: Hashable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let intensity: UInt16
    public var status = Status.unknown

    public static func == (lhs: SortablePixel, rhs: SortablePixel) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
    }

    public var description: String {
        return "[\(x), \(y)]"
    }

    public enum Status {
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
}

