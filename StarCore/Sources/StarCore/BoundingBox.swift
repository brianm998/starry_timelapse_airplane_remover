import Foundation
import KHTSwift

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
        let center1X = Double(self.min.x) + Double(self.width)/2
        let center1Y = Double(self.min.y) + Double(self.height)/2

        let center2X = Double(other.min.x) + Double(other.width)/2
        let center2Y = Double(other.min.y) + Double(other.height)/2
    
        let xDist = Double(abs(center1X - center2X))
        let yDist = Double(abs(center1Y - center2Y))

        return sqrt(xDist * xDist + yDist * yDist)
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
            var minX = self.min.x
            if other.min.x > minX { minX = other.min.x }
            var minY = self.min.y
            if other.min.y > minY { minY = other.min.y }

            var maxX = self.max.x
            if other.max.x < maxX { maxX = other.max.x }
            var maxY = self.max.y
            if other.max.y < maxY { maxY = other.max.y }
            
            return BoundingBox(min: Coord(x: minX, y: minY),
                               max: Coord(x: maxX, y: maxY))
        }
        return nil
    }
    
    // returns the number of overlapping pixels divided by the average size of the two boxes
    public func overlapAmount(with other: BoundingBox) -> Double {
        if let overlap = overlap(with: other) {
            let avgSize = (self.size + other.size)/2
            return Double(overlap.size)/Double(avgSize)
        }
        return 0
    }

    // theta in degrees of the line between the centers of the two bounding boxes
    func centerTheta(with box2: BoundingBox) -> Double {
        let box1 = self

        let center1X = Double(box1.min.x) + Double(box1.width)/2
        let center1Y = Double(box1.min.y) + Double(box1.height)/2

        //Log.v("1 center [\(center1X), \(center1Y)]")
        
        let center2X = Double(box2.min.x) + Double(box2.width)/2
        let center2Y = Double(box2.min.y) + Double(box2.height)/2
        
        //Log.v("2 center [\(center2X), \(center2Y)]")

        // special case horizontal alignment, theta 0 degrees
        if center1Y == center2Y { return 0 }

        // special case vertical alignment, theta 90 degrees
        if center1X == center2X { return 90 }

        var theta: Double = 0

        let width = Double(abs(center1X - center2X))
        let height = Double(abs(center1Y - center2Y))

        let ninetyDegreesInRadians = 90 * Double.pi/180
        
        if center1X < center2X {
            if center1Y < center2Y {
                // 90 + case
                theta = ninetyDegreesInRadians + atan(height/width)
            } else { // center1Y > center2Y
                // 0 - 90 case
                theta = atan(width/height)
            }
        } else { // center1X > center2X
            if center1Y < center2Y {
                // 0 - 90 case
                theta = atan(width/height)
            } else { // center1Y > center2Y
                // 90 + case
                theta = ninetyDegreesInRadians + atan(height/width)
            }
        }

        // XXX what about rho?
        let thetaDegrees = theta*180/Double.pi // convert from radians to degrees
        return  thetaDegrees
    }


    
    // positive if they don't overlap, negative if they do
    public func edgeDistance(to otherBox: BoundingBox) -> Double {

        let halfWidth1 = Double(self.width)/2
        let halfHeight1 = Double(self.height)/2
        
        //Log.v("1 half size [\(halfWidth1), \(halfHeight1)]")
        
        let halfWidth2 = Double(otherBox.width)/2
        let halfHeight2 = Double(otherBox.height)/2
        
        //Log.v("2 half size [\(halfWidth2), \(halfHeight2)]")

        let center1X = Double(self.min.x) + halfWidth1
        let center1Y = Double(self.min.y) + halfHeight1

        //Log.v("1 center [\(center1X), \(center1Y)]")
        
        let center2X = Double(otherBox.min.x) + halfWidth2
        let center2Y = Double(otherBox.min.y) + halfHeight2
        

        //Log.v("2 center [\(center2X), \(center2Y)]")

        if center1Y == center2Y {
            // special case horizontal alignment
            // return the distance between their centers minus half of each of their widths
            return Double(abs(center1X - center2X) - halfWidth1 - halfWidth2)
        }

        if center1X == center2X {
            // special case vertical alignment
            // return the distance between their centers minus half of each of their heights
            return Double(abs(center1Y - center2Y) - halfHeight1 - halfHeight2)
        }

        // calculate slope and y intercept for the line between the center points
        // y = slope * x + yIntercept
        let slope = Double(center1Y - center2Y)/Double(center1X - center2X)

        // base the yIntercept on the center 1 coordinates
        let yIntercept = Double(center1Y) - slope * Double(center1X)

        //Log.v("slope \(slope) yIntercept \(yIntercept)")
        
        var theta: Double = 0

        // width between center points
        let width = Double(abs(center1X - center2X))

        // height between center points
        let height = Double(abs(center1Y - center2Y))

        let ninetyDegreesInRadians = 90 * Double.pi/180

        if center1X < center2X {
            if center1Y < center2Y {
                // 90 + case
                theta = ninetyDegreesInRadians + atan(height/width)
            } else { // center1Y > center2Y
                // 0 - 90 case
                theta = atan(width/height)
            }
        } else { // center1X > center2X
            if center1Y < center2Y {
                // 0 - 90 case
                theta = atan(width/height)
            } else { // center1Y > center2Y
                // 90 + case
                theta = ninetyDegreesInRadians + atan(height/width)
            }
        }

        //Log.v("theta \(theta*180/Double.pi) degrees")
        
        // the distance along the line between the center points that lies within group 1
        let dist1 = distanceOn(box: self, slope: slope, yIntercept: yIntercept, theta: theta)
        //Log.v("dist1 \(dist1)")
        
        // the distance along the line between the center points that lies within group 2
        let dist2 = distanceOn(box: otherBox, slope: slope, yIntercept: yIntercept, theta: theta)

        //Log.v("dist2 \(dist2)")

        // the direct distance bewteen the two centers
        let centerDistance = sqrt(width * width + height * height)

        //Log.v("centerDistance \(centerDistance)")
        
        // return the distance between their centers minus the amount of the line which is within each group
        // will be positive if the distance is separation
        // will be negative if they overlap
        let ret = centerDistance - dist1 - dist2
        //Log.v("returning \(ret)")
        return ret
    }

    
}

// the distance between the center point of the box described and the exit of the line from it
fileprivate func distanceOn(box boundingBox: BoundingBox,
                         slope: Double, yIntercept: Double, theta: Double) -> Double
{
    var edge: Edge = .horizontal
    let yMaxValue = Double(boundingBox.max.x)*slope + Double(yIntercept)
    let xMaxValue = Double(boundingBox.max.y)-yIntercept/slope

    // there is an error introduced by integer to floating point conversions
    let mathAccuracyError: Double = 3
    
    if Double(boundingBox.min.y) - mathAccuracyError <= yMaxValue && yMaxValue <= Double(boundingBox.max.y) + mathAccuracyError {
        edge = .vertical
    } else if Double(boundingBox.min.x) - mathAccuracyError <= xMaxValue && xMaxValue <= Double(boundingBox.max.x) + mathAccuracyError {
        edge = .horizontal
    } else {
        // is this really a problem? not sure
        //Log.v("the line generated from the given slope and line does not intersect the rectangle given")
    }

    var hypotenuseLength: Double = 0
    
    switch edge {
    case .vertical:
        let halfWidth = Double(boundingBox.width)/2
        //Log.v("vertical halfWidth \(halfWidth)")
        hypotenuseLength = halfWidth / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let halfHeight = Double(boundingBox.height)/2
        //Log.v("horizontal halfHeight \(halfHeight)")
        hypotenuseLength = halfHeight / cos(theta)
    }
    
    return hypotenuseLength
}
