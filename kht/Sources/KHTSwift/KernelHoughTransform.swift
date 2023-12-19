import kht_bridge

let DEGREES_TO_RADIANS = atan(1.0) / 45.0
let RADIANS_TO_DEGREES = 45 / atan(1.0)

public func kernelHoughTransform(image: [UInt16],
                                 width: Int32,
                                 height: Int32, 
                                 clusterMinSize: Int32 = 10,
                                 clusterMinDeviation: Double = 2.0,
                                 delta: Double = 0.5,
                                 kernelMinHeight: Double = 0.002,
                                 nSigmas: Double = 2.0) -> [Line]
{
    var ret: [Line] = []

    // for some reason the KHT code munges the input array, so copy it
    var mutableImage = image 
    
    mutableImage.withUnsafeMutableBufferPointer() { imagePtr in
        if let lines = KHTBridge.translate(imagePtr.baseAddress,
                                           width: width,
                                           height: width,
                                           clusterMinSize: clusterMinSize,
                                           clusterMinDeviation: clusterMinDeviation,
	                                   delta: delta,
                                           kernelMinHeight: kernelMinHeight,
                                           nSigmas: nSigmas)
        {
            for line in lines {
                if let line = line as? KHTBridgeLine {
                    // convert kht polar central origin polar coords to
                    // two points that are on the line
                    //print("kht line.theta \(line.theta) line.rho \(line.rho) line.count \(line.count)")

                    // two points that are on this line
                    let (p1, p2) = line.coords(width: width, height: height)

                    //print("p1 \(p1) p2 \(p2)")

                    // construct a new theta and rho using upper left polar coords
                    let (new_theta, new_rho) = polarCoords(point1: p1, point2: p2)

                    //print("new_theta \(new_theta), new_rho \(new_rho)\n")

                    let newLine = Line(theta: new_theta,
                                       rho: new_rho,
                                       count: Int(line.count))

                    var shouldAppend = true

                    // check lines we are already going to return to see
                    // if there are any closely matching lines that had a
                    // higher count.  If so, this line is basically noise,
                    // don't return it.
                    for lineToReturn in ret {
                        if lineToReturn.matches(newLine,
                                                maxThetaDiff: 5,
                                                maxRhoDiff: 2)
                        {
                            shouldAppend = false
                            break
                        }
                    }

                    if shouldAppend {
                        ret.append(newLine)
                    }
                }
            }
        }
    }
    return ret
}

extension KHTBridgeLine {

    func coords(width: Int32, height: Int32) -> (DoubleCoord, DoubleCoord) {
        // this logic is copied from main.cpp
        // it converts the central origin polar coords
        // returned from kht to two points on the line

        var p1x = 0.0
        var p1y = 0.0
        var p2x = 0.0
        var p2y = 0.0

        let widthD = Double(width)
        let heightD = Double(height)

        let rho = self.rho
        let theta = self.theta * DEGREES_TO_RADIANS
        let cos_theta = cos(theta)
        let sin_theta = sin(theta)

        if sin_theta != 0.0 {
            p1x = -widthD * 0.5
	    p1y = (rho - p1x * cos_theta) / sin_theta
	    
            p2x = widthD * 0.5 - 1
	    p2y = (rho - p2x * cos_theta) / sin_theta
        } else {
            // vertical
            p1x = rho
	    p1y = -heightD * 0.5
	    
            p2x = rho
	    p2y = heightD * 0.5 - 1
        }
        
        p1x += widthD * 0.5
        p1y += heightD * 0.5
        p2x += widthD * 0.5
        p2y += heightD * 0.5

        let p1 = DoubleCoord(x: p1x, y: p1y)
        let p2 = DoubleCoord(x: p2x, y: p2y)
        
        return (p1, p2)
    }
}

// x, y coordinates
public struct Coord: Codable {
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

// x, y coordinates
public struct DoubleCoord: Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func standardLine(with otherPoint: DoubleCoord) -> StandardLine {
        let dx1 = self.x
        let dy1 = self.y
        let dx2 = otherPoint.x
        let dy2 = otherPoint.y

        let x_diff = dx1-dx2
        let y_diff = dy1-dy2

        let slope = y_diff / x_diff

        // y - dy2 = slope*(x - dx2)
        // y/slope - dy2/slope = x - dx2
        // -1*x + 1/slope * y = dy2/slope - dx2
        // -1*x + 1/slope * y - (dy2/slope - dx2) = 0

        let a = -1.0
        let b = 1/slope
        let c = -(dy2/slope - dx2)

        return StandardLine(a: a, b: b, c: c)
    }
}

public struct StandardLine {
    // a*x + b*y + c = 0

    let a: Double
    let b: Double
    let c: Double


    func intersection(with otherLine: StandardLine) -> DoubleCoord {

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

        return (theta, rho)
    } else if dy1 == dy2 {
        // horizontal case

        let theta = 90.0
        let rho = Double(dy1)
        
        return (theta, rho)
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
         direction, and neeed to account for it.
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
        var rho = sqrt(meetPoint.x*meetPoint.x+meetPoint.y*meetPoint.y)

        // sometimes rho needs to be negative, 
        // if theta is pointing away from the line
        // reverse theta and keep rho positive
        
        let yAtZeroX = origStandardLine.yAtZeroX

        if (yAtZeroX < 0 && theta < 180) ||
           (yAtZeroX > 0 && theta > 180)
        {
            theta = (theta + 180).truncatingRemainder(dividingBy: 360)
        }
        
        return (theta, rho)
    }
}

