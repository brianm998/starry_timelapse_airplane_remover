import Foundation

// describes a line by the standard formula of a*x + b*y + c = 0
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
