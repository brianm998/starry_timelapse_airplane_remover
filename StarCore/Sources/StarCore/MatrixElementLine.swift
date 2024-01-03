import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 Holds a spot in an image matrix, and a line associated with it.
 
 This line has its origin point at element.x, element.y
 */
public struct MatrixElementLine {
    public let element: ImageMatrixElement
    public let line: Line
    public let frameIndex: Int

    public init(element: ImageMatrixElement,
                line: Line,
                frameIndex: Int)

    {
        self.element = element
        self.line = line
        self.frameIndex = frameIndex
    }
    
    // combine these elements
    func combine(with other: MatrixElementLine) -> MatrixElementLine {
        // do both element and line combination

        if other.frameIndex != self.frameIndex {
            fatalError("cannot combine frames from different indices - \(other.frameIndex) != \(self.frameIndex)")
        }

        // calculate proper x, y, width and height
        var minX = self.element.x
        if other.element.x < minX { minX = other.element.x }
        
        var minY = self.element.y
        if other.element.y < minY { minY = other.element.y }

        var maxWidth = self.element.x + self.element.width
        if other.element.x + other.element.width > maxWidth {
            maxWidth = other.element.x + other.element.width
        }
        
        var maxHeight = self.element.y + self.element.height
        if other.element.y + other.element.height > maxHeight {
            maxHeight = other.element.y + other.element.height
        }

        let combinedElement = ImageMatrixElement(x: minX, y: minY,
                                                 width: maxWidth,
                                                 height: maxHeight)
        // calculate line 

        let combinedOriginZeroLine = self.originZeroLine.combine(with: other.originZeroLine)

        let (op1, op2) = combinedOriginZeroLine.twoPoints

        let line = Line(point1: DoubleCoord(x: op1.x-Double(minX), y: op1.y-Double(minY)),
                        point2: DoubleCoord(x: op2.x-Double(minX), y: op2.y-Double(minY)),
                        votes: combinedOriginZeroLine.votes)

        return MatrixElementLine(element: combinedElement, line: line, frameIndex: frameIndex)
    }

    public var originZeroLine: Line {
        // the line here has its origin at element.x and element.y

        // get two raster points that are on the line
        let (op1, op2) = line.twoPoints

        // add element.x and element.y to them
        // convert back to Line
        return Line(point1: DoubleCoord(x: op1.x + Double(element.x),
                                        y: op1.y + Double(element.y)),
                    point2: DoubleCoord(x: op2.x + Double(element.x),
                                        y: op2.y + Double(element.y)),
                    votes: line.votes)
    }
}

