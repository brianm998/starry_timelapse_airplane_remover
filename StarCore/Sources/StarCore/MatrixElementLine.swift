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
    let element: ImageMatrixElement
    let line: Line

    // combine these elements
    func combine(with other: MatrixElementLine) -> MatrixElementLine {
        // do both element and line combination

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

        return MatrixElementLine(element: combinedElement, line: line)
    }

    var originZeroLine: Line {
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

extension Line {
    public func iterate(on elementLine: MatrixElementLine,
                        withExtension lineExtension: Int = 0, // extend this far in each direction
                        closure: (Int, Int, IterationDirection) -> Void)
    {
        let element = elementLine.element
        
        // where does this line intersect the edges of this element?
        let frameEdgeMatches = self.frameBoundries(width: element.width,
                                                   height: element.height)

        if frameEdgeMatches.count == 2 {
            // calculate a standard line from the edge matches
            let standardLine = StandardLine(point1: frameEdgeMatches[0],
                                            point2: frameEdgeMatches[1])

            // calculate line orientation
            let x_diff = abs(frameEdgeMatches[0].x - frameEdgeMatches[1].x)
            let y_diff = abs(frameEdgeMatches[0].y - frameEdgeMatches[1].y)
            
            // iterate on the longest axis
            let iterateOnXAxis = x_diff > y_diff

            if iterateOnXAxis {

                let startX = -lineExtension+element.x
                let endX = element.width+lineExtension + element.x

                //Log.d("frame \(frameIndex) iterating on X axis from \(startX)..<\(endX) lastBlob \(lastBlob)")
                
                for elementX in -lineExtension..<element.width+lineExtension {
                    let elementY = Int(standardLine.y(forX: Double(elementX)))

                    let x = elementX+element.x
                    let y = elementY+element.y

                    if x >= 0,
                       y >= 0
                    {
                        closure(x, y, .horizontal)
                    }
                }
            } else {
                // iterate on y axis

                let startY = -lineExtension+element.y
                let endY = element.height+lineExtension + element.y

                //Log.d("frame \(frameIndex) iterating on Y axis from \(startY)..<\(endY) lastBlob \(lastBlob)")

                for elementY in -lineExtension..<element.height+lineExtension {
                    let elementX = Int(standardLine.x(forY: Double(elementY)))

                    let x = elementX+element.x
                    let y = elementY+element.y

                    if x >= 0,
                       y >= 0
                    {
                        closure(x, y, .vertical)
                    }
                }
            }
        } else {
            Log.i("cannot iterate with \(frameEdgeMatches.count) edge matches")
        }
    }
}

public enum IterationDirection {
    case vertical
    case horizontal
}
