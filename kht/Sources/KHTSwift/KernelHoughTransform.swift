import kht_bridge
import CoreGraphics
import Cocoa

let DEGREES_TO_RADIANS = atan(1.0) / 45.0
let RADIANS_TO_DEGREES = 45 / atan(1.0)

// this swift method wraps an objc method which wraps a c++ implementation
// of kernel based hough transormation
// we convert the coordinate system of the returned lines, and filter them a bit
// these default parameter values need more documentation.  All but the last
// two were taken from main.cpp from the kht implementation.
public func kernelHoughTransform(image: NSImage,
                                 clusterMinSize: Int32 = 10,
                                 clusterMinDeviation: Double = 2.0,
                                 delta: Double = 0.5,
                                 kernelMinHeight: Double = 0.002,
                                 nSigmas: Double = 2.0,
                                 maxThetaDiff: Double = 5,
                                 maxRhoDiff: Double = 2,
                                 minCount: Int = 20) -> [Line]
{
    var ret: [Line] = []

    // first get a list of lines from the kernel based hough transform
    if let lines = KHTBridge.translate(image,
                                       clusterMinSize: clusterMinSize,
                                       clusterMinDeviation: clusterMinDeviation,
	                               delta: delta,
                                       kernelMinHeight: kernelMinHeight,
                                       nSigmas: nSigmas)
    {
        print("got \(lines.count) lines")

        var count = 0
        
        for line in lines {
            if let line = line as? KHTBridgeLine {
                // change how each line is represented

                // convert kht polar central origin polar coord line
                // two a line polar coord origin at [0, 0]
                let newLine = line.leftCenterOriginLine(width: Int32(image.size.width),
                                                        height: Int32(image.size.height))
                
                var shouldAppend = true


                if newLine.count < minCount {
                    // ignore lines with small counts
                    shouldAppend = false
                } else {
                    // check lines we are already going to return to see
                    // if there are any closely matching lines that had a
                    // higher count.  If so, this line is basically noise,
                    // don't return it.
                    for lineToReturn in ret {
                        if lineToReturn.matches(newLine,
                                                maxThetaDiff: maxThetaDiff,
                                                maxRhoDiff: maxRhoDiff)
                        {
                            shouldAppend = false
                            break
                        }
                    }
                }

                if shouldAppend {
                    if count < 4 {
                        print("KHT line \(count) theta \(line.theta) rho \(line.rho)")
                    }
                    ret.append(newLine)
                    count += 1
                }
            }
        }
    }
    return ret
}

extension KHTBridgeLine {

    // returns a line with polar coord origin at [0, 0]
    func leftCenterOriginLine(width: Int32, height: Int32) -> Line {

        // the kht lib uses polar coordinates with
        // the origin centered on the image
        
        // the star app uses polar coordinates with
        // the origin at pixel [0, 0]
        
        // get two points that are on this line
        let (p1, p2) = self.coords(width: width, height: height)

        // construct a new line based upon these points
        return Line(point1: p1,
                    point2: p2,
                    count: Int(self.count))
    }

    
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

// x, y coordinates as doubles
public struct DoubleCoord: Codable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public var hasNaN: Bool { x.isNaN || y.isNaN }

    public var isFinite: Bool { x.isFinite && y.isFinite }
    
    public func standardLine(with otherPoint: DoubleCoord) -> StandardLine {
        let dx1 = self.x
        let dy1 = self.y
        let dx2 = otherPoint.x
        let dy2 = otherPoint.y

        let x_diff = dx1-dx2
        let y_diff = dy1-dy2

        if x_diff == 0 {
            // vertical line
            // x = c
            // 1*x + 0*y - c = 0
            
            return StandardLine(a: 1, b: 0, c: -dx1)
        } else if y_diff == 0 {
            // horizontal line
            // y = c
            // 0*x + 1*y - c = 0
            
            return StandardLine(a: 0, b: 1, c: -dy1)
        } else {
        
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
}
