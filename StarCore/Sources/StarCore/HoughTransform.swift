import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


// this class does a hough transform on the inputData var into the counts var
// inputData is rows of a matrix of dataWidth and dataHeight
// users should input their data into inputData before calling the lines method.
public class HoughTransform {

    let dataWidth: Int
    let dataHeight: Int
    let rmax: Double            // maximum rho possible

    // y axis is rho, double for negivative values, middle is zero
    let houghHeight: Int       // units are rho (pixels)

    // x axis is theta, always 0 to 360
    let houghWidth = 360       // units are theta (degrees)

    public var inputData: [UInt16]
    var counts: [[Double]]
    
    let dr: Double
    let dth: Double

    public convenience init(dataWidth: Int, dataHeight: Int) {
        self.init(dataWidth: dataWidth,
                 dataHeight: dataHeight,
                 inputData: [UInt16](repeating: 0, count: dataWidth*dataHeight))
    }

    public init(dataWidth: Int, dataHeight: Int, inputData: [UInt16]) {
        self.dataWidth = dataWidth
        self.dataHeight = dataHeight
        self.rmax = sqrt(Double(dataWidth*dataWidth + dataHeight*dataHeight))
        self.houghHeight = Int(rmax*2) // units are rho (pixels)
        self.dr   = 2 * rmax / Double(houghHeight);
        self.dth  = Double.pi / Double(houghWidth);
        self.counts = [[Double]](repeating: [Double](repeating: 0, count: houghHeight),
                                 count: Int(houghWidth))
        self.inputData = inputData
    }

    func resetCounts() {
        for (x, row) in self.counts.enumerated() {
            for(y, _) in row.enumerated() {
                counts[x][y] = 0
            }
        }
    }
    
    public func lines(maxCount: Int? = nil,                  // max number of lines to return
                      minPixelValue: Int16 = 1000) -> [Line] // the dimmest pixel we will process
    {
        // accumulate the hough transform data in counts from the input data
        // this can take a long time when there are lots of input points

        // iterate through all pixels of the input image
        for x in 0 ..< self.dataWidth {
            for y in 0 ..< self.dataHeight {
                // record tracing polar coordinates for all
                // lines that can go through this pixel
                
                // recording dimmer pixels can take a long time,
                // and not add much signal to the tranform data

                // not recording a pixel means that a faint line
                // can be missed, and not returned in the output data

                // how bright is this pixel?
                let offset = (y * dataWidth) + x
                let pixelValue = inputData[offset]

                if pixelValue > minPixelValue {
                    // record all possible lines that transit this pixel
                    for k in 0 ..< Int(houghWidth) {
                        let th = dth * Double(k)
                        let r2 = (Double(x)*cos(th) + Double(y)*sin(th))
                        let iry = Int(rmax + r2/dr)
                        let newValue = counts[k][iry]+Double(pixelValue)
                        counts[k][iry] = newValue
                    }
                }
            }
        }

        var lines: [Line] = []
        
        // grab theta, rho and count values from the transform
        // this is faster than the loop above by about 5x, depending
        // upon number of points processed above 
        for x in 0 ..< houghWidth {
            for y in 0 ..< houghHeight {
                let count = counts[x][y]
                if count == 0  { continue }     // ignore cells with no count

                var is3x3max = true
                
                // left neighbor
                if x > 0,
                   count <= counts[x-1][y]        { is3x3max = false }
                
                // left upper neighbor                    
                else if x > 0, y > 0,
                        count <= counts[x-1][y-1] { is3x3max = false }
                
                // left lower neighbor                    
                else if x > 0,
                        y < houghHeight - 1,
                        count <= counts[x-1][y+1] { is3x3max = false }
                
                // upper neighbor                    
                else if y > 0,
                        count <= counts[x][y-1]   { is3x3max = false }
                
                // lower neighbor                    
                else if y < houghHeight - 1,
                        count <= counts[x][y+1]   { is3x3max = false }
                
                // right neighbor
                else if x < houghWidth - 1,
                        count <= counts[x+1][y]   { is3x3max = false }
                
                // right upper neighbor                    
                else if x < houghWidth - 1,
                        y > 0,
                        count <= counts[x+1][y-1] { is3x3max = false }
                
                // right lower neighbor                    
                else if x < houghWidth - 1,
                        y < houghHeight - 1,
                        count <= counts[x+1][y+1] { is3x3max = false }
                
                else if is3x3max {
                    var theta = Double(x)/2.0 // why /2 ?
                    var rho = Double(y) - rmax
                    
                    if(rho < 0) {
                        // keeping rho positive
                        //Log.d("reversing orig rho \(rho) theta \(theta)")
                        rho = -rho
                        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
                    }
                    
                    lines.append(Line(theta: theta, rho: rho, count: Int(count)))
                }
            }
        }

        // put higher counts at the front of the list
        let sortedLines = lines.sorted() { $0.count > $1.count }

        var linesToReturn: Array<Line> = []
        if let maxCount = maxCount {
            // return lines with the highest counts at the front of the list
            linesToReturn = Array<Line>(sortedLines.prefix(maxCount))
        } else {
            // return them all
            // this list can be exhaustive
            linesToReturn = sortedLines
        }

        return linesToReturn
    }        
}

// this method returns the polar coords for a line that runs through the two given points
// not used anymore in the current implementation
func polarCoords(point1: Coord, point2: Coord) -> (theta: Double, rho: Double) {
    
    let dx1 = Double(point1.x)
    let dy1 = Double(point1.y)
    let dx2 = Double(point2.x)
    let dy2 = Double(point2.y)

    let slope = (dy1-dy2)/(dx1-dx2)
    
    let n = dy1 - slope * dx1    // y coordinate at zero x
    let m = -n/slope            // x coordinate at zero y
    
    // length of hypotenuse formed by triangle of (0, 0) - (0, n) - (m, 0)
    let hypotenuse = sqrt(n*n + m*m)
    let thetaRadians = acos(n/hypotenuse)     // theta in radians
    
    var theta = thetaRadians * 180/Double.pi  // theta in degrees
    var rho = cos(thetaRadians) * m          // distance from orgin to right angle with line
    
    if(rho < 0) {
        // keep rho positive
        rho = -rho
        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
    }
    return (theta: theta,  // degrees from the X axis, clockwise
           rho: rho)      // distance to right angle with line from origin in pixels
}

