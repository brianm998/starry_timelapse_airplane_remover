import Foundation
import kht_bridge
import logging

public let DEGREES_TO_RADIANS = atan(1.0) / 45.0
public let RADIANS_TO_DEGREES = 45 / atan(1.0)


// this swift method wraps a c++ implementation
// of kernel based hough transformation
// we convert the coordinate system of the returned lines, and filter them a bit
// these default parameter values need more documentation.  All but the last
// four were taken from main.cpp from the kht implementation.
public func kernelHoughTransform(image: MatWrapper,
                                 width: Int,
                                 height: Int,
                                 // never return more than this many lines
                                 // returns all if not given
                                 maxResults: Int? = nil) -> [Line]
{
    var ret: [Line] = []

    var outLines: UnsafeMutablePointer<KHTLine>?
    let count = kht_translate(image.ref, &outLines)

    if count > 0, let lines = outLines {
        for i in 0..<Int(count) {
            if let maxResults,
               ret.count >= maxResults { break }

            let khtLine = lines[i]

            // change how each line is represented
            // convert kht polar central origin polar coord line
            // to a line polar coord origin at [0, 0]
            let newLine = leftCenterOriginLine(
                rho: khtLine.rho, theta: khtLine.theta, votes: Int(khtLine.votes),
                width: Int32(width), height: Int32(height)
            )

            ret.append(newLine)
        }
        kht_free_lines(lines)
    }

    return ret
}

// returns a line with polar coord origin at [0, 0]
private func leftCenterOriginLine(rho: Double, theta: Double, votes: Int,
                                   width: Int32, height: Int32) -> Line {
    let (p1, p2) = khtCoords(rho: rho, theta: theta, width: width, height: height)
    return Line(point1: p1, point2: p2, votes: votes)
}

private func khtCoords(rho: Double, theta: Double,
                        width: Int32, height: Int32) -> (DoubleCoord, DoubleCoord) {
    // this logic is copied from main.cpp
    // it converts the central origin polar coords
    // returned from kht to two points on the line

    var p1x = 0.0
    var p1y = 0.0
    var p2x = 0.0
    var p2y = 0.0

    let widthD = Double(width)
    let heightD = Double(height)

    let thetaRad = theta * DEGREES_TO_RADIANS
    let cos_theta = cos(thetaRad)
    let sin_theta = sin(thetaRad)

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
