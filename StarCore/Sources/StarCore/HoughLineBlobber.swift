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
        let contrastDetectionSize: Double = 5
        
        for elementLine in houghLines {
            Log.d("frame \(frameIndex) processing elementLine \(elementLine)")
            let element = elementLine.element
            let line = elementLine.originZeroLine

            // the point on the line which is perpendicular to the origin, in the
            // full frame reference frame
            let rhoX = line.rho * cos(line.theta*DEGREES_TO_RADIANS)
            let rhoY = line.rho * sin(line.theta*DEGREES_TO_RADIANS)

            // parallel lines contrastDetectionSize away from the line we're iterating on
            let boundary1Line = Line(theta: line.theta,
                                     rho: line.rho-contrastDetectionSize)

            let boundary2Line = Line(theta: line.theta,
                                     rho: line.rho+contrastDetectionSize)

            let standardLine = line.standardLine
            
            line.iterate(on: elementLine, withExtension: 256) { x, y, direction in
                if x < imageWidth,
                   y < imageHeight
                {
                    //Log.d("frame \(frameIndex) elementLine \(elementLine) iterate \(x) \(y)")
                    
                    let pixel = self.pixels[x][y]

                    switch pixel.status {
                    case .blobbed(_):
                        break
                    case .unknown:
                        if pixel.intensity > 0xF000 { // XXX constant
                            // create blob here

                            let newBlob = Blob(pixel, frameIndex: frameIndex)
                            blobs.append(newBlob)
                            
                            Log.d("frame \(frameIndex) expanding from seed pixel \(pixel)")
                            
                            expand(blob: newBlob, seedPixel: pixel)
                        } else if pixel.intensity > 0x0F00 { // XXX another constant

                            // do contrast analysis on orthogonal pixels to find blobs
                            
                            // angle from origin to this pixel
                            let pixelTheta = atan(Double(y)/Double(x))*RADIANS_TO_DEGREES
                            
                            /*
                             pixel is behind if theta from x,y is less than theta from line
                             */
                            var perpTheta: Double = 0

                            if pixelTheta > line.theta {
                                perpTheta = line.theta+90
                            } else {
                                perpTheta = line.theta-90
                            }

                            if perpTheta < 0 { perpTheta += 360 }
                            if perpTheta > 360 { perpTheta -= 360 }

                            let xDiff = Double(x) - rhoX
                            let yDiff = Double(y) - rhoY

                            let perpRho = sqrt(xDiff*xDiff + yDiff*yDiff)

                            // a perpendicular line to the line we are iterating on,
                            // which intersects it at x, y
                            let perpLine = Line(theta: perpTheta, rho: perpRho).standardLine

                            // testing
                            // testing
                            // testing
                            // if the math is right, this should be very close to x, y
                            let me = perpLine.intersection(with: line.standardLine)

                            if abs(Double(x)-me.x) < 2,
                               abs(Double(y)-me.y) < 2
                            {
                                // ok
                            } else {
                                fatalError("frame \(frameIndex) coord me WRONG \(direction) \(me) != \(x), \(y) rho [\(Int(rhoX)), \(Int(rhoY))] pixelTheta \(Int(pixelTheta)) lineTheta \(Int(line.theta)) lineRho \(Int(line.rho)) perpTheta \(Int(perpTheta)) perpRho \(Int(perpRho)) xDiff \(Int(xDiff)) yDiff \(Int(yDiff)) elementLine \(elementLine)")
                            }
                            // testing
                            // testing
                            // testing
                            
                            // iterate on this line close to x, y

                            let firstIterationPoint = DoubleCoord(x: Double(x), y: Double(y))

                            let itCoord1 = boundary1Line.standardLine.intersection(with: perpLine)
                            let itCoord2 = boundary2Line.standardLine.intersection(with: perpLine)

                            let fullDistance = itCoord1.distance(to: itCoord2)
                            let coord1Dist = itCoord1.distance(to: firstIterationPoint)
                            let coord2Dist = itCoord2.distance(to: firstIterationPoint)

                            /*
                            if coord1Dist > fullDistance ||
                               coord1Dist > fullDistance
                            {
                                fatalError("HOLY FUCK NUTS \(fullDistance) \(coord1Dist) \(coord2Dist) \(firstIterationPoint) c1 \(itCoord1) c2 \(itCoord2)")
                                }

                                XXX this can happen because of rounding errors between Int and Double :(
                            */
                            let perpPolar = perpLine.polarLine
                            
                            Log.d("frame \(frameIndex) from [\(x), \(y)], iterate from \(itCoord1) to \(itCoord2) on \(perpPolar)")


                            /*

                             iterate from one side of the line to the other

                             keep track of dimmest, brightest, and their locations

                             if, it gets dimmer by the same agreed amount on both sides,
                             and the brightest spot is close enough to the line,

                             then start a blob at the brightest spot, if pixel not blobbed or backgrounded
                             
                             */
                            // dimmest on one side
                            var dimmest1: UInt16 = 0xFFFF

                            // dimmest on the other side
                            var dimmest2: UInt16 = 0xFFFF
                            
                            var brighest: UInt16 = 0
                            var brightestCoord: DoubleCoord?
                            
                            perpPolar.iterate(between: itCoord1, and: itCoord2) { px, py, dir in
                                if px < imageWidth,
                                   py < imageHeight
                                {
                                    let distance = standardLine.distanceTo(x: px, y: py)
                                    if px >= self.pixels.count {
                                        fatalError("CRAPNUTS x \(px) >= \(self.pixels.count)")
                                    }
                                    if px < 0 {
                                        fatalError("CRAPNUTS x \(px) >= \(self.pixels.count)")
                                    }
                                    let fuck = self.pixels[px]

                                    if py >= fuck.count {
                                        fatalError("CRAPNUTS y \(py) >= \(fuck.count)")
                                    }
                                    
                                    let pixel = self.pixels[px][py]
                                    let coord = DoubleCoord(x: Double(px), y: Double(py))

                                    if pixel.intensity > brighest {
                                        brighest = pixel.intensity
                                        brightestCoord = coord
                                    }

                                    let dist1 = itCoord1.distance(to: coord)
                                    let dist2 = itCoord2.distance(to: coord)
                                    if dist1 < dist2 {
                                        if pixel.intensity < dimmest1 { dimmest1 = pixel.intensity }
                                    } else {
                                        if pixel.intensity < dimmest2 { dimmest2 = pixel.intensity }
                                    }
                                }
                            }

                            // how many times brighter does the middle peak have to be?
                            //let brightnessThreshold = 20.0 // XXX constant
                            let brightnessThreshold = 50.0 // XXX constant
                            //let brightnessThreshold = 100.0 // XXX constant

                            // how far away can the brighest coord be from the line?
                            let distanceThreshold = 2.0   // XXX constant

                            let minBrightness = 0x1000 // XXX constant
                            //let minBrightness = 0x0B00 // too small
                            //let minBrightness = 800 // too small
                            
                            if brighest > minBrightness, 
                               Double(brighest)/Double(dimmest1) > brightnessThreshold,
                               Double(brighest)/Double(dimmest2) > brightnessThreshold,
                               let brightestCoord = brightestCoord,
                               standardLine.distanceTo(brightestCoord) < distanceThreshold
                            {
                                let pixel = self.pixels[Int(brightestCoord.x)][Int(brightestCoord.y)]
                                switch pixel.status {
                                case .unknown:
                                    let newBlob = Blob(pixel, frameIndex: frameIndex)
                                    blobs.append(newBlob)
                                    Log.d("frame \(frameIndex) expanding from seed pixel \(pixel)")
                                    expand(blob: newBlob, seedPixel: pixel)
                                    
                                case .background:
                                    break
                                    
                                case .blobbed(_):
                                    break
                                }
                            }
                        }
                        
                    case .background:
                        break
                    }
                } else {
                    //Log.d("frame \(frameIndex) elementLine \(elementLine) OUT OF BOUNDS iterate \(x) \(y)")
                }
            }
        }

        // filter blobs here

        self.blobs = self.blobs.filter { $0.size > 20 }
    }
}
