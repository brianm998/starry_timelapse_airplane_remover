import Foundation

// these values are used for creating an initial config when processing a new sequence
public struct Defaults {

    /*
     The outlier max and min thresholds below are percentages of how much a
     pixel is brighter than the same pixel in adjecent frames.

     If a pixel is outlierMinThreshold percentage brighter, then it is an outlier.
     If a pixel is brighter than outlierMaxThreshold, then it is painted over fully.
     If a pixel is between these two values, then an alpha between 0-1 is applied.

     A lower outlierMaxThreshold results in detecting more outlier groups.
     A higher outlierMaxThreshold results in detecting fewer outlier groups.
     */
    public static let outlierMaxThreshold: Double = 9
    public static let outlierMinThreshold: Double = 7

    // groups smaller than this are completely ignored
    // this is scaled by image size:
    //   12 megapixels will get this value
    //   larger ones more, smaller less 
    public static let minGroupSize: Int = 20
}

// make any string into an Error, so it can be thrown by itself if desired
extension String: Error {}

// x, y coordinates
public struct Coord: Codable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

// polar coordinates for right angle intersection with line from origin
public struct Line: Codable {
    public let theta: Double                 // angle in degrees
    public let rho: Double                   // distance in pixels
    public let count: Int                    // higher count is better fit for line

    // convert to rise over run, y intercept if possible
    public var cartesianLine: CartesianLine? {
        // the line goes through this point
        let line_intersection_x = self.rho*cos(self.theta*Double.pi/180)
        let line_intersection_y = self.rho*sin(self.theta*Double.pi/180)

        var edge_1_x = 0.0
        var edge_1_y = 0.0

        var y_intercept = 0.0
        if self.theta == 0 || self.theta == 360 {
            // vertical line
            edge_1_x = self.rho
            edge_1_y = 0

            Log.e("SPECIAL CASE NOT HANDLED")
            return nil
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
        } else if self.theta < 270 {
            Log.e("WTF, theta \(self.theta)?")

            // these lines can't draw into the image unless rho is negative
            // and that is accounted for elsewhere by reversing theta 180,
            // and inverting rho
            
            Log.e("SPECIAL CASE NOT HANDLED")
            return nil
        } else if self.theta < 360 {
            let opposite = tan((360-self.theta)*Double.pi/180)*self.rho
            edge_1_x = sqrt(opposite*opposite + self.rho*self.rho)
            edge_1_y = 0

            y_intercept = -(self.rho / cos((self.theta-270)*Double.pi/180))
        }

        let rise_over_run = (edge_1_y - line_intersection_y) / (edge_1_x - line_intersection_x)

        //Log.d("for theta \(self.theta) rho \(self.rho) intersection [\(line_intersection_x), \(line_intersection_y)], edge 1 [\(edge_1_x), \(edge_1_y)] rise over run \(rise_over_run) y_intercept \(y_intercept)")
        
        return CartesianLine(m: rise_over_run, c: y_intercept)
    }
}

public struct CartesianLine {
    public let m: Double                // rise over run
    public let c: Double                // y intercept

    public func y(for x: Int) -> Int {
        // y = m*x + c
        Int(m*Double(x) + c)
    }
}

public enum Edge {
    case vertical
    case horizontal
}


