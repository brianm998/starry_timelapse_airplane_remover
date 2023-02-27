import Foundation

// the bounding box of an outlier group
public struct BoundingBox: Codable {
    public let min: Coord
    public let max: Coord

    public init(min: Coord, max: Coord) {
        self.min = min
        self.max = max
    }
    
    public var width:  Int { self.max.x - self.min.x + 1 }
    public var height: Int { return self.max.y - self.min.y + 1 }
    public var size:   Int { width * height }
    
    public var hypotenuse: Double {
        let width = Double(self.width)
        let height = Double(self.height)
        return sqrt(width*width + height*height)
    }

    public var center: Coord {
        Coord(x: Int(Double(self.min.x) + Double(self.width)/2),
              y: Int(Double(self.min.y) + Double(self.height)/2))
    }

    // use for decision tree?
    public func centerDistance(to other: BoundingBox) -> Double {
        let center_1_x = Double(self.min.x) + Double(self.width)/2
        let center_1_y = Double(self.min.y) + Double(self.height)/2

        let center_2_x = Double(other.min.x) + Double(other.width)/2
        let center_2_y = Double(other.min.y) + Double(other.height)/2
    
        let x_dist = Double(abs(center_1_x - center_2_x))
        let y_dist = Double(abs(center_1_y - center_2_y))

        return sqrt(x_dist * x_dist + y_dist * y_dist)
    }

    // true if this BoundingBox fully contains the other
    public func contains(other: BoundingBox) -> Bool {
        return self.min.x <= other.min.x &&
               self.max.x >= other.max.x &&
               self.min.y <= other.min.y &&
               self.max.y >= other.max.y
    }
    
    public func overlap(with other: BoundingBox) -> BoundingBox? {
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
    public func overlapAmount(with other: BoundingBox) -> Double {
        if let overlap = overlap(with: other) {
            let avg_size = (self.size + other.size)/2
            return Double(overlap.size)/Double(avg_size)
        }
        return 0
    }

    // positive if they don't overlap, negative if they do
    public func edgeDistance(to other_box: BoundingBox) -> Double {

        let half_width_1 = Double(self.width)/2
        let half_height_1 = Double(self.height)/2
        
        //Log.v("1 half size [\(half_width_1), \(half_height_1)]")
        
        let half_width_2 = Double(other_box.width)/2
        let half_height_2 = Double(other_box.height)/2
        
        //Log.v("2 half size [\(half_width_2), \(half_height_2)]")

        let center_1_x = Double(self.min.x) + half_width_1
        let center_1_y = Double(self.min.y) + half_height_1

        //Log.v("1 center [\(center_1_x), \(center_1_y)]")
        
        let center_2_x = Double(other_box.min.x) + half_width_2
        let center_2_y = Double(other_box.min.y) + half_height_2
        

        //Log.v("2 center [\(center_2_x), \(center_2_y)]")

        if center_1_y == center_2_y {
            // special case horizontal alignment
            // return the distance between their centers minus half of each of their widths
            return Double(abs(center_1_x - center_2_x) - half_width_1 - half_width_2)
        }

        if center_1_x == center_2_x {
            // special case vertical alignment
            // return the distance between their centers minus half of each of their heights
            return Double(abs(center_1_y - center_2_y) - half_height_1 - half_height_2)
        }

        // calculate slope and y intercept for the line between the center points
        // y = slope * x + y_intercept
        let slope = Double(center_1_y - center_2_y)/Double(center_1_x - center_2_x)

        // base the y_intercept on the center 1 coordinates
        let y_intercept = Double(center_1_y) - slope * Double(center_1_x)

        //Log.v("slope \(slope) y_intercept \(y_intercept)")
        
        var theta: Double = 0

        // width between center points
        let width = Double(abs(center_1_x - center_2_x))

        // height between center points
        let height = Double(abs(center_1_y - center_2_y))

        let ninety_degrees_in_radians = 90 * Double.pi/180

        if center_1_x < center_2_x {
            if center_1_y < center_2_y {
                // 90 + case
                theta = ninety_degrees_in_radians + atan(height/width)
            } else { // center_1_y > center_2_y
                // 0 - 90 case
                theta = atan(width/height)
            }
        } else { // center_1_x > center_2_x
            if center_1_y < center_2_y {
                // 0 - 90 case
                theta = atan(width/height)
            } else { // center_1_y > center_2_y
                // 90 + case
                theta = ninety_degrees_in_radians + atan(height/width)
            }
        }

        //Log.v("theta \(theta*180/Double.pi) degrees")
        
        // the distance along the line between the center points that lies within group 1
        let dist_1 = distance_on(box: self, slope: slope, y_intercept: y_intercept, theta: theta)
        //Log.v("dist_1 \(dist_1)")
        
        // the distance along the line between the center points that lies within group 2
        let dist_2 = distance_on(box: other_box, slope: slope, y_intercept: y_intercept, theta: theta)

        //Log.v("dist_2 \(dist_2)")

        // the direct distance bewteen the two centers
        let center_distance = sqrt(width * width + height * height)

        //Log.v("center_distance \(center_distance)")
        
        // return the distance between their centers minus the amount of the line which is within each group
        // will be positive if the distance is separation
        // will be negative if they overlap
        let ret = center_distance - dist_1 - dist_2
        //Log.v("returning \(ret)")
        return ret
    }

    
}

// the distance between the center point of the box described and the exit of the line from it
fileprivate func distance_on(box bounding_box: BoundingBox,
                             slope: Double, y_intercept: Double, theta: Double) -> Double
{
    var edge: Edge = .horizontal
    let y_max_value = Double(bounding_box.max.x)*slope + Double(y_intercept)
    let x_max_value = Double(bounding_box.max.y)-y_intercept/slope
    //let y_min_value = Double(min_x)*slope + Double(y_intercept)
    //let x_min_value = Double(bounding_box.min.y)-y_intercept/slope

    // there is an error introduced by integer to floating point conversions
    let math_accuracy_error: Double = 3
    
    if Double(bounding_box.min.y) - math_accuracy_error <= y_max_value && y_max_value <= Double(bounding_box.max.y) + math_accuracy_error {
        //Log.v("vertical")
        edge = .vertical
    } else if Double(bounding_box.min.x) - math_accuracy_error <= x_max_value && x_max_value <= Double(bounding_box.max.x) + math_accuracy_error {
        //Log.v("horizontal")
        edge = .horizontal
    } else {
        //Log.v("slope \(slope) y_intercept \(y_intercept) theta \(theta)")
        //Log.v("min_x \(min_x) x_max_value \(x_max_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.v("bounding_box.min.y \(bounding_box.min.y) y_max_value \(y_max_value) bounding_box.max.y \(bounding_box.max.y)")
        //Log.v("min_x \(min_x) x_min_value \(x_min_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.v("bounding_box.min.y \(bounding_box.min.y) y_min_value \(y_min_value) bounding_box.max.y \(bounding_box.max.y)")
        // this means that the line generated from the given slope and line
        // does not intersect the rectangle given 

        // can happen for situations of overlapping areas like this:
        //(1119 124),  (1160 153)
        //(1122 141),  (1156 160)

        // is this really a problem? not sure
        //Log.v("the line generated from the given slope and line does not intersect the rectangle given")
    }

    var hypotenuse_length: Double = 0
    
    switch edge {
    case .vertical:
        let half_width = Double(bounding_box.width)/2
        //Log.v("vertical half_width \(half_width)")
        hypotenuse_length = half_width / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let half_height = Double(bounding_box.height)/2
        //Log.v("horizontal half_height \(half_height)")
        hypotenuse_length = half_height / cos(theta)
    }
    
    return hypotenuse_length
}
