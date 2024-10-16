import kht_bridge
import CoreGraphics
import logging
import Cocoa

public let DEGREES_TO_RADIANS = atan(1.0) / 45.0
public let RADIANS_TO_DEGREES = 45 / atan(1.0)


// this swift method wraps an objc method which wraps a c++ implementation
// of kernel based hough transformation
// we convert the coordinate system of the returned lines, and filter them a bit
// these default parameter values need more documentation.  All but the last
// four were taken from main.cpp from the kht implementation.
public func kernelHoughTransform(image: NSImage,
                                 // never return more than this many lines
                                 // returns all if not given
                                 maxResults: Int? = nil) -> [Line]
{
    transformer.kernelHoughTransform(image: image,
                                     maxResults: maxResults)
}

/*

 Isolate the c++ code within an actor as it is not thread safe.

 Thankfully this kernel hough transform is fast, so isolating it doesn't slow us down much
 
 */
fileprivate let transformer = HoughTransformer()

fileprivate final class HoughTransformer: Sendable {

    public func kernelHoughTransform(image: NSImage,
                                     maxResults: Int?) -> [Line]
    {
        var ret: [Line] = []

        // first get a list of lines from the kernel based hough transform
        if let lines = KHTBridge.translate(image) {
            //Log.d("got \(lines.count) lines")

            for line in lines {
                if let line = line as? KHTBridgeLine {
                    if let maxResults,
                       ret.count >= maxResults { return ret }
                    
                    // change how each line is represented

                    // convert kht polar central origin polar coord line
                    // two a line polar coord origin at [0, 0]
                    let newLine = line.leftCenterOriginLine(width: Int32(image.size.width),
                                                            height: Int32(image.size.height))
                    
                    ret.append(newLine)
                }
            }
        }
        return ret
    }
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
                    votes: Int(self.votes))
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
