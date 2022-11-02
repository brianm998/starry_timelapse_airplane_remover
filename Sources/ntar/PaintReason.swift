import Foundation

// will we paint a group or not, and why
typealias WillPaint = (                 
    shouldPaint: Bool,          // paint over this group or not
    why: PaintReason            // why?
)

// why we are or are not painting a group
enum PaintReason: Equatable {
   case assumed                      // large groups are assumed to be airplanes
   case goodScore(Double)            // percent score
   case adjecentLine(Double, Double, Int)     // theta and rho diffs, plus count

   case badScore(Double)        // percent score
   case adjecentOverlap(Int) // overlap distance
   case tooBlobby(Double, Double) // first_diff, lowest_diff  XXX more info here
        
   public static func == (lhs: PaintReason, rhs: PaintReason) -> Bool {
      switch lhs {
      case assumed:
          switch rhs {
          case assumed:
              return true
          default:
              return false
          }
      case goodScore:
          switch rhs {
          case goodScore:
              return true
          default:
              return false
          }
      case adjecentLine:
          switch rhs {
          case adjecentLine:
              return true
          default:
              return false
          }
      case badScore:
          switch rhs {
          case badScore:
              return true
          default:
              return false
          }
      case adjecentOverlap:
          switch rhs {
          case adjecentOverlap:
              return true
          default:
              return false
          }
      case tooBlobby: 
          switch rhs {
          case tooBlobby:
              return true
          default:
              return false
          }
      }
   }    
}

