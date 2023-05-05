import Foundation

// why we are or are not painting a group
public enum PaintReason: Equatable, CaseIterable, Codable {

   case userSelected(Bool)      // true if should paint

   case fromClassifier(Double)      // 1 if should paint, -1 if not

   public var BasicColor: BasicColor {
        get {
            switch self {
            case .userSelected(let willPaint):
                if willPaint {
                    return .red
                } else {
                    return .green
                }
            case .fromClassifier(let willPaint):
                if willPaint > 0 {
                    return .green
                } else {
                    return .red
                }
            }
        }
   }
   
   public var name: String {
        get {
            switch self {
            case .userSelected(let willPaint): return "user selected \(willPaint)"
            case .fromClassifier(let willPaint): return "decision tree \(willPaint)"
            }
        }
   }

   public var description: String {
        get {
            switch self {
            case .userSelected:
                return """
These outlier groups were selected specifically by user in gui.
"""
            case .fromClassifier:
                return """
These outlier groups were selected specifically by user in gui.
"""
            }
        }
   }

   public var willPaint: Bool {
        get {
            switch self {
            case .userSelected(let willPaint):
                return willPaint
            case .fromClassifier(let willPaint):
                return willPaint > 0
            }
        }
   }

   public static var shouldPaintCases: [PaintReason] {
       return PaintReason.allCases.filter { $0.willPaint }
   }

   public static var shouldNotPaintCases: [PaintReason] {
       return PaintReason.allCases.filter { !$0.willPaint }
   }

   public static var allCases: [PaintReason] {
       return [.userSelected(false), .fromClassifier(0)]
   }
                         
   // colors used to test paint to show why
   public var testPaintPixel: Pixel { self.BasicColor.pixel }
        
   public static func == (lhs: PaintReason, rhs: PaintReason) -> Bool {
      switch lhs {
      case .userSelected(let lhsWillPaint):
          switch rhs {
          case .userSelected(let rhsWillPaint):
              return lhsWillPaint == rhsWillPaint
          default:
              return false
          }
      case .fromClassifier(let lhsPaintScore):
          switch rhs {
          case .fromClassifier(let rhsPaintScore):
              if lhsPaintScore > 0,
                 rhsPaintScore > 0
              {
                  return true
              } else {
                  return false
              }
          default:
              return false
          }
      }
   }
}
   
