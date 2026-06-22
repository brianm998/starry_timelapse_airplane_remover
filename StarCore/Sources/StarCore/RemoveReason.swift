import Foundation

// why we are or are not removing a group
// Proto mirror: Star_V1_RemoveReason in daemon/proto/star.proto — keep cases in sync.
public enum RemoveReason: Equatable,
                          Codable,
                          Sendable,
                          Hashable
{
   case userSelected(Bool)      // true if should remove
   case fromClassifier(Double)      // 1 if should remove, -1 if not

   public var BasicColor: BasicColor {
        get {
            switch self {
            case .userSelected(let willRemove):
                if willRemove {
                    return .red
                } else {
                    return .green
                }
            case .fromClassifier(let willRemove):
                if willRemove > 0 {
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
            case .userSelected(let willRemove): return "user selected \(willRemove)"
            case .fromClassifier(let willRemove): return "decision tree \(willRemove)"
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

   public var willRemove: Bool {
        get {
            switch self {
            case .userSelected(let willRemove):
                return willRemove
            case .fromClassifier(let willRemove):
                return willRemove > 0
            }
        }
   }

   // colors used to test remove to show why
   public var testRemovePixel: Pixel { self.BasicColor.pixel }
        
   public static func == (lhs: RemoveReason, rhs: RemoveReason) -> Bool {
      switch lhs {
      case .userSelected(let lhsWillRemove):
          switch rhs {
          case .userSelected(let rhsWillRemove):
              return lhsWillRemove == rhsWillRemove
          default:
              return false
          }
      case .fromClassifier(let lhsRemoveScore):
          switch rhs {
          case .fromClassifier(let rhsRemoveScore):
              if lhsRemoveScore > 0,
                 rhsRemoveScore > 0
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
   
