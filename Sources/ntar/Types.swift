import Foundation

// x, y coordinates
typealias Coord = (
    x: Int,
    y: Int
)

// polar coordinates for right angle intersection with line from origin
typealias Line = (                 
    theta: Double,                 // angle in degrees
    rho: Double,                   // distance in pixels
    count: Int                     // higher count is better fit for line
)

// a member in an airplane streak across frames
typealias AirplaneStreakMember = (
  frame_index: Int,
  group_name: String,
  bounds: BoundingBox,
  line: Line
)

// the bounding box of an outlier group
struct BoundingBox {
    let min: Coord
    let max: Coord

    var width: Int {
        return self.max.x - self.min.x + 1
    }
    
    var height: Int {
        return self.max.y - self.min.y + 1
    }
    
    var hypotenuse: Double {
        let width = Double(self.width)
        let height = Double(self.height)
        return sqrt(width*width + height*height)
    }
}

