import Foundation
import CoreGraphics
import Cocoa
import KHTSwift
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 A blobber that blobbs along hough lines
 
 */
public class HoughLineBlobber: AbstractBlobber {

    let houghLines: [MatrixElementLine]
    
    public init(imageWidth: Int,
                imageHeight: Int,
                pixelData: [UInt16],
                frameIndex: Int,
                neighborType: NeighborType,
                contrastMin: Double,
                houghLines: [MatrixElementLine])
    {
        self.houghLines = houghLines
        
        super.init(imageWidth: imageWidth,
                   imageHeight: imageHeight,
                   pixelData: pixelData,
                   frameIndex: frameIndex,
                   neighborType: neighborType,
                   contrastMin: contrastMin)

        // XXX need to actually blob here

        /*
         This blobber will iterate over each hough line in order of highest voted line first

         need to iterate on each point of the line between ends of the matrix element

         if the pixel on the line is bright enough, then simply create a blob there.
         perhaps restrict the blob to a certain distance from the line we're iterating on

         if the pixel on the line is dimmer, apply edge detection by iterating
         again 90 degrees orthogonal to the line, for a small number of pixels, like 10-20.

         */


        // this many pixels on each side of the line
        let contrastDetectionSize: Double = 8
        
        for elementLine in houghLines {
            Log.d("frame \(frameIndex) processing elementLine \(elementLine)")
            let element = elementLine.element
            let line = elementLine.line

            // convert this line into the full frame reference frame, by default
            // the reference frame for this line is the element line
            let (p1, p2) = line.twoPoints

            let ap1 = DoubleCoord(x: p1.x + Double(element.x),
                                  y: p1.y + Double(element.y))
            let ap2 = DoubleCoord(x: p2.x + Double(element.x),
                                  y: p2.y + Double(element.y))

            let adjustedLine = Line(point1: ap1, point2: ap2)
            
            // the point on the line which is perpendicular to the origin, in the
            // full frame reference frame
            let rhoX = adjustedLine.rho * cos(adjustedLine.theta*DEGREES_TO_RADIANS)
            let rhoY = adjustedLine.rho * sin(adjustedLine.theta*DEGREES_TO_RADIANS)
            
            adjustedLine.iterate(on: elementLine, withExtension: 256) { x, y, direction in
                if x < imageWidth,
                   y < imageHeight
                {
                    Log.d("frame \(frameIndex) elementLine \(elementLine) iterate \(x) \(y)")
                    
                    let pixel = pixels[x][y]

                    switch pixel.status {
                    case .blobbed(_):
                        break
                    case .unknown:
                        if pixel.intensity > 2000 { // XXX constant
                            // create blob here

                            let newBlob = Blob(pixel, frameIndex: frameIndex)
                            blobs.append(newBlob)
                            
                            Log.d("frame \(frameIndex) expanding from seed pixel.intensity \(pixel.intensity)")
                            
                            expand(blob: newBlob, seedPixel: pixel)
                        } else if pixel.intensity > 100 { // XXX another constant

                            /*

                             This doesn't work yet, but should be:

                             finding two coords to iterate between that span x, y
                             and are perpendicular to the line here

                             iterate between those coords looking for a specific
                             pattern of dark to bright to dark again.

                             If found, then create a blob from this pixel
                             
                             */
                            // create orthogonal line and detect contrast across it
                            // if contrast is high enough, then blob here

                            // this line HOPEFULLY IS perpendicular to the line we are iterating on

                            // XXX subtract 90 if x,y is behind,
                            // this assumes that it's ahead

                            /*
                             XXX calculate theta for x,y

                             tan(theta) = y/x

                             theta = atan(y/x)
                             */

                            // angle from origin to this pixel
                            let pixelTheta = atan(Double(y)/Double(x))*RADIANS_TO_DEGREES
                            
                            /*
                             pixel is behind if theta from x,y is less than theta from line
                             */
                            var perpTheta: Double = 0

                            if pixelTheta > adjustedLine.theta {
                                perpTheta = adjustedLine.theta+90
                            } else {
                                perpTheta = adjustedLine.theta-90
                            }
                            
                            if perpTheta < 0 { perpTheta += 360 }
                            if perpTheta > 360 { perpTheta -= 360 }

                            let xDiff = Double(x) - rhoX
                            let yDiff = Double(y) - rhoY

                            let perpRho = sqrt(xDiff*xDiff + yDiff*yDiff)

                            let perpLine = Line(theta: perpTheta, rho: perpRho).standardLine

                            // if the math is right, this should be very close to x, y
                            let me = perpLine.intersection(with: adjustedLine.standardLine)

                            /*

                             underlying math error somewhere,
                             some of these are right,
                             some aren't

                             NOT SURE WHY
                             
                             */

                            if abs(Double(x)-me.x) < 5,
                               abs(Double(y)-me.y) < 5
                            {
                                Log.d("frame \(frameIndex) coord me RIGHT \(direction) \(me) == \(x), \(y) rho [\(Int(rhoX)), \(Int(rhoY))] pixelTheta \(Int(pixelTheta)) lineTheta \(Int(line.theta)) lineRho \(Int(adjustedLine.rho)) perpTheta \(Int(perpTheta)) perpRho \(Int(perpRho)) xDiff \(Int(xDiff)) yDiff \(Int(yDiff)) elementLine \(elementLine)")
                            } else {
                                Log.d("frame \(frameIndex) coord me WRONG \(direction) \(me) != \(x), \(y) rho [\(Int(rhoX)), \(Int(rhoY))] pixelTheta \(Int(pixelTheta)) lineTheta \(Int(line.theta)) lineRho \(Int(adjustedLine.rho)) perpTheta \(Int(perpTheta)) perpRho \(Int(perpRho)) xDiff \(Int(xDiff)) yDiff \(Int(yDiff)) elementLine \(elementLine)")
                            }
                            
                            // iterate on this line close to x, y

                            let boundary1Line = Line(theta: adjustedLine.theta,
                                                     rho: adjustedLine.rho-contrastDetectionSize)

                            let boundary2Line = Line(theta: adjustedLine.theta,
                                                     rho: adjustedLine.rho+contrastDetectionSize)

                            let itCoord1 = boundary1Line.standardLine.intersection(with: perpLine)
                            let itCoord2 = boundary2Line.standardLine.intersection(with: perpLine)
                            
                            Log.d("frame \(frameIndex) from [\(x), \(y)], iterate from \(itCoord1) to \(itCoord2)")
                            
                            // XXX make sure this perp line is really perpendicular,
                            // and make a method to iterate within a distance of it
                            // and call a callback that measures the intensity curve
                            // across the iteration, and applies some kind of heuristic
                            // too determine if a blob should be seeded at this x, y 
                        }
                        
                    case .background:
                        break
                    }
                } else {
                    Log.d("frame \(frameIndex) elementLine \(elementLine) OUT OF BOUNDS iterate \(x) \(y)")
                }
            }
        }
    }
}
