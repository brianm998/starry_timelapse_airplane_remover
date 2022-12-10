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

    var width:  Int { self.max.x - self.min.x + 1 }
    var height: Int { return self.max.y - self.min.y + 1 }
    var size:   Int { width * height }
    
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

    func overlap(with other: BoundingBox) -> BoundingBox? {
        if self.min.x < other.max.x,
           self.min.y < other.max.y,
           other.min.x < self.max.x,
           other.min.y < self.max.y
        {
            var min_x = self.min.x
            if other.min.x > min_x { min_x = other.min.x }
            var min_y = self.min.y
            if other.min.y > min_y { min_y = other.min.y }

            var max_x = self.max.x
            if other.max.x < max_x { max_x = other.max.x }
            var max_y = self.max.y
            if other.max.y < max_y { max_y = other.max.y }
            
            return BoundingBox(min: Coord(x: min_x, y: min_y),
                               max: Coord(x: max_x, y: max_y))
        }
        return nil
    }
    
    // returns the number of overlapping pixels divided by the average size of the two boxes
    func overlapAmount(with other: BoundingBox) -> Double {
        if let overlap = overlap(with: other) {
            let avg_size = (self.size + other.size)/2
            return Double(overlap.size)/Double(avg_size)
        }
        return 0
    }
}

