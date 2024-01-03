import Foundation
import KHTSwift

extension Line {
    
    public var iterationDirection: IterationDirection {
        let (p1, p2) = self.twoPoints

        let x_diff = abs(p1.x - p2.x)
        let y_diff = abs(p1.y - p2.y)
        
        // iterate on the longest axis
        let iterateOnXAxis = x_diff > y_diff

        if iterateOnXAxis {
            return .horizontal
        } else {
            return .vertical
        }
    }

    public func iterate(between coord1: DoubleCoord,
                        and coord2: DoubleCoord,
                        closure: (Int, Int, IterationDirection) -> Void)
    {
        let standardLine = self.standardLine

        //Log.i("self.standardLine \(self.standardLine)")
        
        switch self.iterationDirection {
        case .horizontal:
            var minX = coord1.x
            var maxX = coord2.x
            if coord2.x < minX {
                minX = coord2.x
                maxX = coord1.x
            }
            for x in Int(minX)...Int(maxX) {
                let y = Int(standardLine.y(forX: Double(x)))
                if x >= 0,
                   y >= 0
                {
                    closure(x, y, .horizontal)
                }
            }
            
        case .vertical:
            var minY = coord1.y
            var maxY = coord2.y
            if coord2.y < minY {
                minY = coord2.y
                maxY = coord1.y
            }
            for y in Int(minY)...Int(maxY) {
                let x = Int(standardLine.x(forY: Double(y)))
                if x >= 0,
                   y >= 0
                {
                    closure(x, y, .vertical)
                }
            }
        }
    }
    
    public func iterate(on elementLine: MatrixElementLine,
                        withExtension lineExtension: Int = 0, // extend this far in each direction
                        closure: (Int, Int, IterationDirection) -> Void)
    {
        let element = elementLine.element
        
        let standardLine = self.standardLine

        switch self.iterationDirection {
        case .horizontal:

            let startX = -lineExtension+element.x
            let endX = element.width+lineExtension + element.x

            //Log.d("elementLine \(elementLine) iterating on X axis from \(startX)..<\(endX)")
            
            for x in startX..<endX {
                let y = Int(standardLine.y(forX: Double(x)))

                if x >= 0,
                   y >= 0
                {
                    closure(x, y, .horizontal)
                }
            }

        case .vertical:
            // iterate on y axis

            let startY = -lineExtension+element.y
            let endY = element.height+lineExtension + element.y

            //Log.d("elementLine \(elementLine) iterating on Y axis from \(startY)..<\(endY)")

            for y in startY..<endY {
                let x = Int(standardLine.x(forY: Double(y)))

                if x >= 0,
                   y >= 0
                {
                    closure(x, y, .vertical)
                }
            }
        }
    }
}

public enum IterationDirection {
    case vertical
    case horizontal
}
