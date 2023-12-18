import kht_bridge

let DEGREES_TO_RADIANS = atan(1.0) / 45.0

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
                    let (p1, p2) = line.coords(width: width, height: height)

                    // construct a new theta and rho using upper left polar coords
                    let (new_theta, new_rho) = polarCoords(point1: p1, point2: p2)

                    let newLine = Line(theta: new_theta,
                                       rho: new_rho,
                                       count: Int(line.count))

                    var shouldAppend = true

                    // check lines we are already going to return to see
                    // if there are any closely matching lines that had a
                    // higher count.  If so, this line is basically noise,
                    // don't return it.
                    for lineToReturn in ret {
                        if lineToReturn.matches(newLine) {
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

        print("line.theta \(self.theta) line.rho \(self.rho)")
        
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
}

// this method returns the polar coords for a line that runs through the two given points
func polarCoords(point1: DoubleCoord,
                 point2: DoubleCoord) -> (theta: Double, rho: Double)
{
    let dx1 = point1.x
    let dy1 = point1.y
    let dx2 = point2.x
    let dy2 = point2.y

    let slope = (dy1-dy2)/(dx1-dx2)
    
    let n = dy1 - slope * dx1    // y coordinate at zero x
    let m = -n/slope             // x coordinate at zero y
    
    // length of hypotenuse formed by triangle of (0, 0) - (0, n) - (m, 0)
    let hypotenuse = sqrt(n*n + m*m)
    let thetaRadians = acos(n/hypotenuse)     // theta in radians
    
    var theta = thetaRadians * 180/Double.pi  // theta in degrees
    var rho = cos(thetaRadians) * m          // distance from orgin to right angle with line
    
    if(rho < 0) {
        // keep rho positive
        rho = -rho
        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
    }
    return (theta: theta,  // degrees from the X axis, clockwise
           rho: rho)      // distance to right angle with line from origin in pixels
}

