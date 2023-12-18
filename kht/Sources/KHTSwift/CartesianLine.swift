import Foundation

public enum CartesianLine {
    case horizontal(HorizontalCartesianLine)
    case vertical(VerticalCartesianLine)
}


public protocol VerticalCartesianLine {
    func x(for y: Int) -> Int
}

public struct StraightVerticalCartesianLine: VerticalCartesianLine {
    public let x: Double
    
    public func x(for y: Int) -> Int { Int(x) }
}

public struct VerticalCartesianLineImpl: VerticalCartesianLine {
    public let m: Double                // run over rise
    public let c: Double                // y intercept

    public func x(for y: Int) -> Int {
        // x = (y-c)/m
        return Int((Double(y)-c)*m)
    }
}

public protocol HorizontalCartesianLine {
    func y(for x: Int) -> Int 
}

public struct HorizontalCartesianLineImpl: HorizontalCartesianLine {
    public let m: Double                // rise over run
    public let c: Double                // y intercept

    public func y(for x: Int) -> Int {
        // y = m*x + c
        Int(m*Double(x) + c)
    }
}
