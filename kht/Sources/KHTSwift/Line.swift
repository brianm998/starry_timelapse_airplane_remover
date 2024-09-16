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

    // constructs a line that passes through the two given points
    public init(point1: DoubleCoord,
                point2: DoubleCoord,
                votes: Int = 0)
    {
        (self.theta, self.rho) = polarCoords(point1: point1, point2: point2)
        self.votes = votes
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
        
        //Log.d("theta \(theta)")

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

