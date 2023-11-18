import Foundation

// a monochrome pixel that is used by the blobber
public class SortablePixel {
    public let x: Int
    public let y: Int
    public let intensity: UInt16
    public var status = Status.unknown
    
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

    public func contrast(with otherPixel: SortablePixel, maxBright: UInt16 = 0xFFFF) -> Double {
        let diff = abs(Int32(self.intensity) - Int32(otherPixel.intensity))
        return Double(diff) * Double(0xFFFF) / Double(maxBright)
    }
}

