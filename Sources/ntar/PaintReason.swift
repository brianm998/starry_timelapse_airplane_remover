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
   case looksLikeALine

   case badScore(Double)        // percent score
   case adjecentOverlap(Double) // overlap distance

   public var testPaintPixel: Pixel {
       get {
           var pixel = Pixel()
           switch self {
           case .assumed:
               pixel.red = 0xBFFF // purple
               pixel.green = 0x3888
               pixel.blue = 0xA888
           case .goodScore:
                pixel.red = 0xFFFF // yellow
                pixel.green = 0xFFFF
                pixel.blue = 0x0000
           case .looksLikeALine:
                pixel.red = 0xFFFF // red
                pixel.green = 0x0000
                pixel.blue = 0x0000
           case .badScore:
                pixel.green = 0xFFFF // cyan
                pixel.blue = 0xFFFF
                pixel.red = 0x0000
           case .adjecentOverlap:
                pixel.red = 0x0000
                pixel.blue = 0xFFFF // blue
                pixel.green = 0x0000
           }
           return pixel
       }
   }
        
   public static func == (lhs: PaintReason, rhs: PaintReason) -> Bool {
      switch lhs {
      case assumed:
          switch rhs {
          case assumed:
              return true
          default:
              return false
          }
      case looksLikeALine:
          switch rhs {
          case looksLikeALine:
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
      }
   }    
}

