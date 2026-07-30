import Foundation
import logging

// polar coordinates for right angle intersection with line from origin of [0, 0]
public struct Line: Codable, Sendable, Hashable {
    public let theta: Double           // angle in degrees
    public let rho: Double             // distance in pixels
    public let votes: Int

    public init(theta: Double,
                rho: Double,
                votes: Int = 0)
    {
        self.theta = theta
        self.rho = rho
        self.votes = votes
    }

    // constructs a line that passes through the two given points
    public init(point1: DoubleCoord,
                point2: DoubleCoord,
                votes: Int = 0)
    {
        (self.theta, self.rho) = polarCoords(point1: point1, point2: point2)
        self.votes = votes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(theta)
        hasher.combine(rho)
    }
    
    // returns to points that are on this line
    public var twoPoints: (DoubleCoord, DoubleCoord) {
        // this point is always on the line
        let rhoCoord = DoubleCoord(x: rho*cos(theta*DEGREES_TO_RADIANS),
                                   y: rho*sin(theta*DEGREES_TO_RADIANS))

        // make a 45 degree triangle with rho,
        // the hypotenuse is the distance to the line at 45 degrees
        
        let hypoRho = sqrt(rho*rho + rho*rho)
        
        let hypoTheta = theta - 45
        
        let hypoCoord = DoubleCoord(x: hypoRho*cos(hypoTheta*DEGREES_TO_RADIANS),
                                    y: hypoRho*sin(hypoTheta*DEGREES_TO_RADIANS))

        return (rhoCoord, hypoCoord)
    }
    
    // returns a line in standard form a*x + b*y + c = 0 
    public var standardLine: StandardLine {
        let (p1, p2) = self.twoPoints

        return StandardLine(point1: p1, point2: p2)
    }
}


// returns polar coords with (0, 0) origin for the given points
public func polarCoords(point1: DoubleCoord,
                        point2: DoubleCoord) -> (theta: Double, rho: Double)
{
    //Log.d("polarCoords point1 \(point1) point2 \(point2)")
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
        /*
         Both theta and rho are read off the foot of the perpendicular — the point on the
         line closest to the origin.  rho is its distance from the origin and theta is its
         direction, so the two are consistent with each other by construction.

         This used to be done the other way around: theta was guessed first from the angle
         the line rises at, corrected by a pair of sign heuristics, and rho was then found by
         intersecting.  The heuristics only covered lines sloping the same way in x and y —
         the other branch was a bare `90 - line_theta` with no sign correction at all — so a
         line whose closest approach to the origin lay in the negative quadrant came back
         with theta pointing 180 degrees the wrong way.  rho, being a distance, could not
         carry the sign either, and the pair then described the line's mirror image through
         the origin.  14% of point pairs drawn from a grid spanning negative and positive
         coordinates were affected, off by as much as 73 pixels.

         That matters beyond the obvious: OutlierGroup.originZeroLine feeds twoPoints back
         through here after offsetting by bounds.min, and the result drives the
         averageLineVariance / medianLineVariance features, which are measured with
         standardLine.distanceTo against the group's own pixels.  Against a mirrored line
         those distances are meaningless.
         */
        let x_diff = dx1-dx2
        let y_diff = dy1-dy2

        //Log.d("x_diff \(x_diff) y_diff \(y_diff)")

        // the line we were given, in a*x + b*y + c = 0 form
        let origStandardLine = point1.standardLine(with: point2)

        // rho travels along the perpendicular to the line, through the origin.  The line
        // runs along (x_diff, y_diff), so (-y_diff, x_diff) is at a right angle to it.
        // Neither component can be zero here: the vertical and horizontal cases were
        // handled above, so x_diff and y_diff are both non-zero.
        let perpendicularLength = sqrt(x_diff*x_diff + y_diff*y_diff)
        let hypo = 100.0        // arbitrary distance from the origin, scale does not matter
        let perpendicular = DoubleCoord(x: -y_diff/perpendicularLength * hypo,
                                        y:  x_diff/perpendicularLength * hypo)

        // the perpendicular line through the origin.  Only its direction matters, so it is
        // the same line whichever of the two ways round the perpendicular vector points —
        // which is exactly why the meeting point below can be trusted to settle the sign.
        let origin = DoubleCoord(x: 0, y: 0)
        let perpendicularStandardLine = origin.standardLine(with: perpendicular)

        // where the perpendicular meets the line: the closest point on it to the origin
        let meetPoint = perpendicularStandardLine.intersection(with: origStandardLine)

        // rho is the hypotenuse of the meeting point x, y
        let rho = sqrt(meetPoint.x*meetPoint.x+meetPoint.y*meetPoint.y)

        // theta is the direction of that same point, which is what keeps it in step with
        // rho.  A line through the origin has rho 0 and so no direction to read off; fall
        // back to the perpendicular's own direction, which is still well defined.  (Such a
        // line cannot be rebuilt from its polar form regardless, since twoPoints scales
        // both of its points by rho — see LineTests.)
        var theta: Double
        if rho > 0 {
            theta = atan2(meetPoint.y, meetPoint.x)*RADIANS_TO_DEGREES
        } else {
            theta = atan2(perpendicular.y, perpendicular.x)*RADIANS_TO_DEGREES
        }

        // keep theta in 0..<360, matching the vertical and horizontal cases above, which
        // answer 0, 90, 180 and 270
        if theta < 0 { theta += 360 }

        //Log.d("theta \(theta) rho \(rho)")

        return (theta, rho)
    }
}

