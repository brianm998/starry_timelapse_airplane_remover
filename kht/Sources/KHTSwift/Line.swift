import Foundation

// polar coordinates for right angle intersection with line from origin of [0, 0]
public struct Line: Codable {
    public let theta: Double           // angle in degrees
    public let rho: Double             // distance in pixels
    public let count: Int

    public init(theta: Double,
                rho: Double,
                count: Int)
    {
        self.theta = theta
        self.rho = rho
        self.count = count
    }

    // constructs a line that passes through the two given points
    init(point1: DoubleCoord,
         point2: DoubleCoord,
         count: Int = 0)
    {
        (self.theta, self.rho) = polarCoords(point1: point1, point2: point2)
        self.count = count
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
}


// returns polar coords with (0, 0) origin for the given points
public func polarCoords(point1: DoubleCoord,
                        point2: DoubleCoord) -> (theta: Double, rho: Double)
{
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

        let distance_between_points = sqrt(x_diff*x_diff + y_diff*y_diff)

        // calculate the angle of the line
        let line_theta_radians = acos(abs(x_diff/distance_between_points))

        // the angle the line rises from the x axis, regardless of
        // in which direction
        var line_theta = line_theta_radians*RADIANS_TO_DEGREES

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
        
        // the theta we want is perpendicular to the angle of this line
        var theta = line_theta + 90

        // keep theta within 0..<360
        if theta >= 360 { theta -= 360 }

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

        // sometimes rho needs to be negative, 
        // if theta is pointing away from the line
        // flip the theta instead, and keep rho positive in that case
        
        let yAtZeroX = origStandardLine.yAtZeroX

        if (yAtZeroX < 0 && theta < 180) ||
           (yAtZeroX > 0 && theta > 180)
        {
            theta = (theta + 180).truncatingRemainder(dividingBy: 360)
        }
        
        return (theta, rho)
    }
}

