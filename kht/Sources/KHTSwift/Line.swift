import Foundation
import logging

// polar coordinates for right angle intersection with line from origin of [0, 0]
public struct Line: Codable {
    public let theta: Double           // angle in degrees
    public let rho: Double             // distance in pixels
    public let votes: Int

    public init(theta: Double,
                rho: Double,
                votes: Int = 0)
    {
        self.theta = theta
        self.rho = rho
        self.votes = votes
    }

    // average them together using votes
    public func combine(with other: Line) -> Line {
        var maxVotes = self.votes + other.votes
        let selfAmt = Double(self.votes)/Double(maxVotes)
        let otherAmt = Double(other.votes)/Double(maxVotes)
        
        return Line(theta: self.theta*selfAmt + other.theta*otherAmt,
                    rho: self.rho*selfAmt + other.rho*otherAmt,
                    votes: maxVotes)
    }

    // returns to points that are on this line
    public var twoPoints: (DoubleCoord, DoubleCoord) {
        // this point is always on the line
        let rhoCoord = DoubleCoord(x: rho*cos(theta*DEGREES_TO_RADIANS),
                                   y: rho*sin(theta*DEGREES_TO_RADIANS))

        // make a 45 degree triangle with rho,
        // the hypotenuse is the distance to the line at 45 degrees
        
        let hypoRho = sqrt(rho*rho + rho*rho)
        
        let hypoTheta = theta - 45
        
        let hypoCoord = DoubleCoord(x: hypoRho*cos(hypoTheta*DEGREES_TO_RADIANS),
                                    y: hypoRho*sin(hypoTheta*DEGREES_TO_RADIANS))

        return (rhoCoord, hypoCoord)
    }
    
    // returns a line in standard form a*x + b*y + c = 0 
    public var standardLine: StandardLine {
        let (p1, p2) = self.twoPoints

        return StandardLine(point1: p1, point2: p2)
    }
    
    // constructs a line that passes through the two given points
    public init(point1: DoubleCoord,
                point2: DoubleCoord,
                votes: Int = 0)
    {
        (self.theta, self.rho) = polarCoords(point1: point1, point2: point2)
        self.votes = votes
    }

    // returns where this line intersects with a frame of the given size
    public func frameBoundries(width: Int, height: Int) -> [DoubleCoord] {

        let dWidth = Double(width)
        let dHeight = Double(height)
        let upperLeft  = DoubleCoord(x: 0, y: 0)
        let upperRight = DoubleCoord(x: 0, y: dHeight)
        let lowerLeft  = DoubleCoord(x: dWidth, y: 0)
        let lowerRight = DoubleCoord(x: dWidth, y: dHeight)
        
        let leftLine = StandardLine(point1: upperLeft, point2: lowerLeft)
        let rightLine = StandardLine(point1: upperRight, point2: lowerRight)
        let upperLine = StandardLine(point1: upperLeft, point2: upperRight)
        let lowerLine = StandardLine(point1: lowerLeft, point2: lowerRight)

        let standardSelf = self.standardLine

        var coordsInBound: [DoubleCoord] = []

        let leftLineIntersection = leftLine.intersection(with: standardSelf)
        
        if leftLineIntersection.isRational,
           Int(leftLineIntersection.x) >= 0,
           Int(leftLineIntersection.x) <= width,
           Int(leftLineIntersection.y) >= 0,
           Int(leftLineIntersection.y) <= height
        {
            //Log.d("appended leftLineIntersection \(leftLineIntersection)")
            coordsInBound.append(leftLineIntersection)
        } else {
            //Log.d("ignored 1 leftLineIntersection \(leftLineIntersection)")
        }

        let rightLineIntersection = rightLine.intersection(with: standardSelf)
        
        if rightLineIntersection.isRational,
           Int(rightLineIntersection.x) >= 0,
           Int(rightLineIntersection.x) <= width,
           Int(rightLineIntersection.y) >= 0,
           Int(rightLineIntersection.y) <= height
        {
            //Log.d("appended rightLineIntersection \(rightLineIntersection)")
            coordsInBound.append(rightLineIntersection)
        } else {
            //Log.d("ignored 2 rightLineIntersection \(rightLineIntersection)")
        }

        let upperLineIntersection = upperLine.intersection(with: standardSelf)
        
        if upperLineIntersection.isRational,
           Int(upperLineIntersection.x) >= 0,
           Int(upperLineIntersection.x) <= width,
           Int(upperLineIntersection.y) >= 0,
           Int(upperLineIntersection.y) <= height
        {
            //Log.d("appended upperLineIntersection \(upperLineIntersection)")
            coordsInBound.append(upperLineIntersection)
        } else {
            //Log.d("ignored 3 upperLineIntersection \(upperLineIntersection)")
        }

        let lowerLineIntersection = lowerLine.intersection(with: standardSelf)
        
        if lowerLineIntersection.isRational,
           Int(lowerLineIntersection.x) >= 0,
           Int(lowerLineIntersection.x) <= width,
           Int(lowerLineIntersection.y) >= 0,
           Int(lowerLineIntersection.y) <= height
        {
            //Log.d("appended lowerLineIntersection \(lowerLineIntersection)")
            coordsInBound.append(lowerLineIntersection)
        } else {
            //Log.d("ignored 4 lowerLineIntersection \(lowerLineIntersection)")
        }

        //Log.d("coordsInBound.count \(coordsInBound.count)")

        return coordsInBound
    }
    
    public func matches(_ line: Line,
                        maxThetaDiff: Double = 5,
                        maxRhoDiff: Double = 5) -> Bool
    {
        let rhoDiff = abs(self.rho - line.rho)
        let thetaDiff = abs(self.theta - line.theta)

        if rhoDiff > maxRhoDiff { return false }

        if thetaDiff > maxThetaDiff {
            // diff is bigger, check to make sure we're not comparing across the
            // 360 degree boundary
            let threeSixtyTheta = abs(thetaDiff - 360)
            if threeSixtyTheta < maxThetaDiff {
                // handles the case of comparing 359 and 0
                return true
            }
            return false
        }

        return true
    }

    public func thetaMatch(_ line: Line,
                           maxThetaDiff: Double = 5) -> Bool
    {
        var selfTheta = self.theta
        var otherTheta = line.theta

        if selfTheta > 180 { selfTheta -= 180 }
        if otherTheta > 180 { otherTheta -= 180 }
        
        let thetaDiff = abs(selfTheta - otherTheta)

        if thetaDiff > maxThetaDiff {
            // diff is bigger, check to make sure we're not comparing 179 and 1

            var largerTheta = selfTheta
            var smallerTheta = otherTheta
            if otherTheta > selfTheta {
                largerTheta = otherTheta
                smallerTheta = selfTheta
            }

            if smallerTheta + 180 - largerTheta < maxThetaDiff {
                // handles the case of comparing 179 and 1
                return true
            }
            return false
        }

        return true
    }
}


// returns polar coords with (0, 0) origin for the given points
public func polarCoords(point1: DoubleCoord,
                        point2: DoubleCoord) -> (theta: Double, rho: Double)
{
    //Log.d("polarCoords point1 \(point1) point2 \(point2)")
    let dx1 = point1.x
    let dy1 = point1.y
    let dx2 = point2.x
    let dy2 = point2.y

    if dx1 == dx2 {
        // vertical case

        let rho = Double(dx1)
        if rho > 0 {
            return (0, rho)
        } else {
            return (180, -rho)
        }
    } else if dy1 == dy2 {
        // horizontal case

        let rho = Double(dy1)

        if rho > 0 {
            return (90, rho)
        } else {
            return (270, -rho)
        }
    } else {
        let x_diff = dx1-dx2
        let y_diff = dy1-dy2

        var isPositiveInBothDirections = false
        
        if dx1 < dx2,
           dy1 < dy2
        {
            isPositiveInBothDirections = true 
            //Log.d("case 1")
        } else if dx1 > dx2,
                  dy1 > dy2
        {
            isPositiveInBothDirections = true 
            //Log.d("case 2")
        } else {
            //Log.d("case 3")
        }

        //Log.d("x_diff \(x_diff) y_diff \(y_diff)")
        
        let distance_between_points = sqrt(x_diff*x_diff + y_diff*y_diff)

        //Log.d("distance_between_points \(distance_between_points)")
        
        // calculate the angle of the line
        let line_theta_radians = acos(abs(x_diff/distance_between_points))

        // the angle the line rises from the x axis, regardless of
        // in which direction
        var line_theta = line_theta_radians*RADIANS_TO_DEGREES

        //Log.d("line_theta \(line_theta)")

        var theta: Double = 0.0
        if isPositiveInBothDirections {
            let standardLine = point1.standardLine(with: point2)
            /* check y value at x = 0
               if negative, use line_theta - 90
               if positive, use line_theta + 90

               positive rho in both cases
             */

            let yAtZeroX = standardLine.y(forX: 0)
            //Log.d("yAtZeroX \(yAtZeroX)")
            if yAtZeroX < 0 {
                theta = line_theta - 90
            } else {
                theta = line_theta + 90
            }
        } else {
            theta = 90-line_theta
        }

        /*
         after handling directly vertical and horiontal lines as sepecial cases above,
         all lines we are left with fall into one of two categories,
         sloping up, or down.  If the line slops up in y,
         then the theta calculated is what we want.
         If the line slops down in y however,
         we're going in the other direction, and neeed to account for that.
         */
        
        var needFlip = false
        if dx1 < dx2 {
            if dy2 < dy1 {
                needFlip = true
            }
        } else {
            if dy1 < dy2 {
                needFlip = true
            }
        }
        
        // in this orientation, the angle is moving in the reverse direction,
        // so make it negative, and keep it between 0..<360
        if needFlip { line_theta = 360 - line_theta }
        
        Log.d("theta \(theta)")

        // next get rho

        // start with the stardard line definition for the line we were given
        let origStandardLine = point1.standardLine(with: point2)

        // our intersection line passes through the origin at 0, 0
        let origin = DoubleCoord(x: 0, y: 0)

        // next find another point at an arbitrary distance from the origin,
        // on the line with the same theta
        
        let hypo = 100.0         // arbitrary distance value

        // find points hypo pixels from the origin on this line
        let parallel_x = hypo * cos(theta*DEGREES_TO_RADIANS)
        let parallel_y = hypo * sin(theta*DEGREES_TO_RADIANS)
        
        // this point is on the line that rho travels on, at
        // an arbitrary distance from the origin.  
        let parallelCoord = DoubleCoord(x: parallel_x, y: parallel_y)

        // use the new point to get the standard line definition for
        // the line between the origin and the right angle intersection with
        // the passed line
        let parallelStandardLine = origin.standardLine(with: parallelCoord)

        // get the intersection point between the two lines
        // rho is between this line and the origin
        let meetPoint = parallelStandardLine.intersection(with: origStandardLine)

        // rho is the hypotenuse of the meeting point x, y
        let rho = sqrt(meetPoint.x*meetPoint.x+meetPoint.y*meetPoint.y)

        return (theta, rho)
    }
}

