import Foundation

// describes a line by the standard formula of a*x + b*y + c = 0
public struct StandardLine {
    // a*x + b*y + c = 0

    let a: Double
    let b: Double
    let c: Double

    public init(a: Double,
                b: Double,
                c: Double)
    {
        self.a = a
        self.b = b
        self.c = c
    }

    // calculate a standard line from two points that are on the line
    public init(point1: DoubleCoord, point2: DoubleCoord) {
        //print("standard line with point1 \(point1) point2 \(point2)")
        self = point1.standardLine(with: point2)
    }

    // gives a line with polar coordinates with origin at [0, 0]
    public var polarLine: Line {
        let x_intercept = DoubleCoord(x: 0, y: self.y(forX: 0))
        let y_intercept = DoubleCoord(x: self.x(forY: 0), y: 0)

        print("x_intercept \(x_intercept) y_intercept \(y_intercept)")

        if x_intercept.isFinite {
            if y_intercept.isFinite {
                // this line intersects both y and x axes
                return Line(point1: x_intercept,
                            point2: y_intercept)
            } else {
                // no Y intercept, but intercepts x, this is a vertical line
                return Line(point1: x_intercept,
                            point2: DoubleCoord(x: 10, y: self.y(forX: 10)))
            }
        } else {
            if y_intercept.isFinite {
                // no X intercept, but intercepts y, this is a horizontal line
                return Line(point1: DoubleCoord(x: self.x(forY: 10), y: 10),
                            point2: y_intercept)
            } else {
                // this line doesn't intersect either access? WTF
                fatalError("somehow this line a = \(a) b = \(b) c = \(c) does not cross either the y or x axes")
            }
        }
    }
    
    public func y(forX x: Double) -> Double {
        // a*x + b*y + c = 0
        // a*x + b*y = -c
        // b*y = -c - a*x 
        // y = (-c - a*x)/b
        return (-c - a*x)/b
    }

    public func x(forY y: Double) -> Double {
        // a*x + b*y + c = 0
        // a*x + b*y = -c
        // a*x = -c - b*y
        // x = (-c - b*y)/a
        return (-c - b*y)/a
    }
    
    public func intersection(with otherLine: StandardLine) -> DoubleCoord {

        let a1 = self.a
        let b1 = self.b
        let c1 = self.c

        let a2 = otherLine.a
        let b2 = otherLine.b
        let c2 = otherLine.c

        return DoubleCoord(x: (b1*c2-b2*c1)/(a1*b2-a2*b1),
                           y: (c1*a2-c2*a1)/(a1*b2-a2*b1))
    }

    var yAtZeroX: Double {
        // b*y + c = 0
        // b*y = -c
        // y = -c/b
        return -c/b
    }
}
