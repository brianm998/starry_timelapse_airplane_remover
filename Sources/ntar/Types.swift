import Foundation

extension String: Error {}

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

enum Edge {
    case vertical
    case horizontal
}

// a member in an airplane streak across frames
@available(macOS 10.15, *) 
typealias AirplaneStreakMember = (
  frame_index: Int,
  group: OutlierGroup,
  distance: Double?      // the distance from this member to the previous one, nil if first member
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

    func centerDistance(to other: BoundingBox) -> Double {
        let center_1_x = Double(self.min.x) + Double(self.width)/2
        let center_1_y = Double(self.min.y) + Double(self.height)/2

        let center_2_x = Double(other.min.x) + Double(other.width)/2
        let center_2_y = Double(other.min.y) + Double(other.height)/2
    
        let x_dist = Double(abs(center_1_x - center_2_x))
        let y_dist = Double(abs(center_1_y - center_2_y))

        return sqrt(x_dist * x_dist + y_dist * y_dist)
    }
}

