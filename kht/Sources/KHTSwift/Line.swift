import Foundation

// polar coordinates for right angle intersection with line from origin
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

