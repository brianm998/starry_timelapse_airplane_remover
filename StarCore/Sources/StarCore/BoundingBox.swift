import Foundation
import KHTSwift
import logging

extension ImageMatrixElement {
    var boundingBox: BoundingBox {
        BoundingBox(min: Coord(x: self.x, y: self.y),
                    max: Coord(x: self.x + self.width,
                               y: self.y + self.height))
    }
}

// the bounding box of an outlier group
public struct BoundingBox: Codable, Equatable {
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

    public static func == (lhs: BoundingBox, rhs: BoundingBox) -> Bool {
        lhs.min == rhs.min && lhs.max == rhs.max 
    }
    
    public var center: Coord {
        Coord(x: Int(Double(self.min.x) + Double(self.width)/2),
              y: Int(Double(self.min.y) + Double(self.height)/2))
    }

    public var centerDouble: DoubleCoord {
        DoubleCoord(x: Double(self.min.x) + Double(self.width)/2,
                    y: Double(self.min.y) + Double(self.height)/2)
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
        self.min.x <= other.min.x &&
        self.max.x >= other.max.x &&
        self.min.y <= other.min.y &&
        self.max.y >= other.max.y
    }

    public func contains(x: Int, y: Int) -> Bool {
         self.min.x <= x &&
         self.max.x >= x &&
         self.min.y <= y &&
         self.max.y >= y
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

    // XXX this method sucks

    /*

     rewrite it to use the center points of the bounding boxes to define a standard line

     figure out what edge point on each bounding box intersects this line

     find the point where they intersect

     return the distance between the intersection points, negative if they overlap
     
     */
    // positive if they don't overlap, negative if they do
    public func edgeDistance(to otherBox: BoundingBox) -> Double {


        /*
         check to see if one of these boxes is completely within the bounds of the other.

         If so, return the size of the smaller blob as the edge distance as negative
         */

        if self.contains(otherBox) {
            // other box is completely within self
            return Double(-otherBox.size)
        } else if otherBox.contains(self) {
            // self is completely with other box
            return Double(-self.size)
        }


        let boxesOverlap = self.overlaps(otherBox)
        
        //Log.d("self \(self) edge distance to \(otherBox) boxesOverlap \(boxesOverlap)")
        let selfCenter = self.centerDouble
        let otherCenter = otherBox.centerDouble

        //Log.d("selfCenter \(selfCenter) otherCenter \(otherCenter)")
        
        let line = StandardLine(point1: selfCenter, point2: otherCenter)

        // floating point math can have small errors
        let mathErrorBuffer = 3.0
        
        let centerDistance = selfCenter.distance(to: otherCenter)
        let selfIntersections = self.intersections(with: line)
        let otherIntersections = otherBox.intersections(with: line)
        
        var selfClosest: DoubleCoord?
        var otherClosest: DoubleCoord?
        
        for point in selfIntersections {
            let distance = point.distance(to: otherCenter)
            //Log.d("self intersection point \(point) distance \(distance) centerDistance \(centerDistance)")
            if boxesOverlap {
                if Int(distance) >= Int(centerDistance-mathErrorBuffer) { // XXX this fails when one is inside the other
                    selfClosest = point
                }
            } else {
                if Int(distance) <= Int(centerDistance+mathErrorBuffer) { // XXX this fails when one is inside the other
                    selfClosest = point
                }
            }
        }
        
        for point in otherIntersections {
            let distance = point.distance(to: selfCenter)
            //Log.d("other intersection point \(point) distance \(distance) centerDistance \(centerDistance)")
            if boxesOverlap {
                if Int(distance) >= Int(centerDistance-mathErrorBuffer) { // XXX this fails when one is inside the other
                    otherClosest = point
                }
            } else {
                if Int(distance) <= Int(centerDistance+mathErrorBuffer) { // XXX fails when one is inside the other
                    otherClosest = point
                }
            }
        }

        if let selfClosest {
            if let otherClosest {

                let selfClosestDist = selfCenter.distance(to: selfClosest)
                let otherClosestDist = otherCenter.distance(to: otherClosest)

                // how far away are the closest points?
                let dist = selfClosest.distance(to: otherClosest)
                
                if selfClosestDist + otherClosestDist < centerDistance {
                    // these boxes do not overlap
                    return dist
                } else {
                    // these boxes do overlap
                    return -dist
                }
            } else {
                // we have no other closest, use other center instead
                Log.i("normal edge distance from \(self) to \(otherBox) could not be determined")
                return selfClosest.distance(to: otherCenter)
            }
        } else {
            // we have no self closest, use other closest instead
            if let otherClosest {
                // we have other closest, but not self
                Log.i("normal edge distance from \(self) to \(otherBox) could not be determined")
                return otherClosest.distance(to: selfCenter)
            } else {
                // we have no closest, but not self
                Log.i("normal edge distance from \(self) to \(otherBox) could not be determined")
                return centerDistance
            }
        }
    }

    public func contains(_ other: BoundingBox) -> Bool {
        self.contains(coord: DoubleCoord(other.min)) && self.contains(coord: DoubleCoord(other.max))
    }
    
    public func overlaps(_ other: BoundingBox) -> Bool {
        let overlapInX =
          (self.min.x <= other.min.x && self.min.x >= other.max.x) ||
          (self.max.x <= other.min.x && self.max.x >= other.max.x)

        let overlapInY =
          (self.min.y <= other.min.y && self.min.y >= other.max.y) ||
          (self.max.y <= other.min.y && self.max.y >= other.max.y)
        
        return overlapInX && overlapInY
    }
    
    public func contains(coord: DoubleCoord) -> Bool {
        if coord.isRational {
            let coord = Coord(coord)
            
            if coord.x >= Int(min.x),
               coord.x <= Int(max.x),
               coord.y >= Int(min.y),
               coord.y <= Int(max.y)
            {
                //Log.d("self \(self) contains \(coord) == true")
                return true
            }
            //Log.d("self \(self) contains \(coord) == false")
        }
        return false
    }
    
    public func intersections(with line: StandardLine) -> [DoubleCoord] {
        //Log.d("intersections of \(self) with line \(line)")
        var ret: [DoubleCoord] = []

        let minY = Double(min.y)
        let minX = Double(min.x)
        let maxY = Double(max.y)
        let maxX = Double(max.x)
        
        let yForMinX = line.y(forX: minX)
        
        if yForMinX > minY,
           yForMinX <= maxY
        {
            //Log.d("yForMinX \(yForMinX) is within range")
            ret.append(DoubleCoord(x: minX, y: yForMinX))
        } else {
            //Log.d("yForMinX \(yForMinX) is NOT within range")
        }

        let yForMaxX = line.y(forX: maxX)
            
        if yForMaxX > minY,
           yForMaxX <= maxY
        {
            //Log.d("yForMaxX \(yForMaxX) is within range")
            ret.append(DoubleCoord(x: maxX, y: yForMaxX))
        } else {
            //Log.d("yForMaxX \(yForMaxX) is NOT within range")
        }
        
        let xForMinY = line.x(forY: minY)

        if xForMinY > minX,
           xForMinY <= maxX
        {
            //Log.d("xForMinY \(xForMinY) is within range")
            ret.append(DoubleCoord(x: xForMinY, y: minY))
        } else {
            //Log.d("xForMinY \(xForMinY) is NOT within range")
        }
        
        let xForMaxY = line.x(forY: maxY)

        if xForMaxY > minX,
           xForMaxY <= maxX
        {
            //Log.d("xForMaxY \(xForMaxY) is within range")
            ret.append(DoubleCoord(x: xForMaxY, y: maxY))
        } else {
            //Log.d("xForMaxY \(xForMaxY) is NOT within range")
        }            

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
