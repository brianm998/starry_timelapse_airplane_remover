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

    init(point1: DoubleCoord,
         point2: DoubleCoord,
         count: Int)
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
    
    // convert to rise over run, y intercept if possible
    // also supports run over rise, as well as vertical only lines
    public var cartesianLine: CartesianLine {
        // the line goes through this point
        let line_intersection_x = self.rho*cos(self.theta*Double.pi/180)
        let line_intersection_y = self.rho*sin(self.theta*Double.pi/180)

        var edge_1_x = 0.0
        var edge_1_y = 0.0

        var y_intercept: Double?
        if self.theta == 0 || self.theta == 360 {
            // vertical line
            edge_1_x = self.rho
            edge_1_y = 0

            // y_intercept not defined
        } else if self.theta < 90 {
            // search for x as hypotenuse 
            let opposite = tan(self.theta*Double.pi/180)*self.rho
            edge_1_x = sqrt(opposite*opposite + self.rho*self.rho)
            edge_1_y = 0

            y_intercept = self.rho / sin(self.theta*Double.pi/180)
        } else if self.theta == 90 {
            // flat horizontal line
            edge_1_x = 0
            edge_1_y = self.rho

            y_intercept = self.rho
            
        } else if self.theta < 180 {
            let opposite = tan((self.theta-90)*Double.pi/180)*self.rho
            edge_1_x = 0
            edge_1_y = sqrt(opposite*opposite + self.rho*self.rho)

            y_intercept = self.rho / cos((self.theta-90)*Double.pi/180)
        } else if self.theta == 180 {
            edge_1_x = self.rho
            edge_1_y = 0

            // y_intercept not defined
        } else if self.theta < 270 {
            //Log.e("WTF, theta \(self.theta)?")

            // these lines can't draw into the image unless rho is negative
            // and that is accounted for elsewhere by reversing theta 180,
            // and inverting rho
            
            //Log.e("theta \(self.theta) \(self.rho) SPECIAL CASE NOT HANDLED")

        } else if self.theta < 360 {
            let opposite = tan((360-self.theta)*Double.pi/180)*self.rho
            edge_1_x = sqrt(opposite*opposite + self.rho*self.rho)
            edge_1_y = 0

            y_intercept = -(self.rho / cos((self.theta-270)*Double.pi/180))
        }

        let run = edge_1_x - line_intersection_x
        let rise = edge_1_y - line_intersection_y
        
        //Log.d("for theta \(self.theta) rho \(self.rho) intersection [\(line_intersection_x), \(line_intersection_y)], edge 1 [\(edge_1_x), \(edge_1_y)] rise over run \(rise_over_run) y_intercept \(y_intercept)")
        if let y_intercept = y_intercept {
            if self.theta < 45 {
                let run_over_rise = run / rise
                return .vertical(VerticalCartesianLineImpl(m: run_over_rise, c: y_intercept))
            } else if self.theta < 135 {
                let rise_over_run = rise / run
                return .horizontal(HorizontalCartesianLineImpl(m: rise_over_run, c: y_intercept))
            } else if self.theta < 225 {
                let run_over_rise = run / rise
                return .vertical(VerticalCartesianLineImpl(m: run_over_rise, c: y_intercept))
            } else if self.theta < 315 {
                let rise_over_run = rise / run
                return .horizontal(HorizontalCartesianLineImpl(m: rise_over_run, c: y_intercept))
            } else {
                let run_over_rise = run / rise
                return .vertical(VerticalCartesianLineImpl(m: run_over_rise, c: y_intercept))
            }
        } else {
            return .vertical(StraightVerticalCartesianLine(x: self.rho))
        }
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

        let theta = 0.0
        let rho = Double(dx1)
        if rho > 0 {
            return (theta, rho)
        } else {
            return (180.0, -rho)
        }
    } else if dy1 == dy2 {
        // horizontal case

        let theta = 90.0
        let rho = Double(dy1)

        if rho > 0 {
            return (theta, rho)
        } else {
            return (270.0, -rho)
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
         sloping up, or down.  If the line slops up, then the theta calculated is
         what we want.  If the line slops down however, we're going in the other
         direction, and neeed to account for that.
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

