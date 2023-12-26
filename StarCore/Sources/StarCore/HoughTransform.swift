import Foundation
import CoreGraphics
import KHTSwift
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

    // how many pixels in each direction does a line have
    // to have numerical domanance to be considered a line
    let maxValueRange: Int
    
    public var inputData: [UInt16]
    var counts: [[Double]]
    
    let dr: Double
    let dth: Double

    public convenience init(dataWidth: Int, dataHeight: Int) {
        self.init(dataWidth: dataWidth,
                 dataHeight: dataHeight,
                 inputData: [UInt16](repeating: 0, count: dataWidth*dataHeight))
    }

    public init(dataWidth: Int,
                dataHeight: Int,
                inputData: [UInt16],
                maxValueRange: Int = 5)
    {
        self.dataWidth = dataWidth
        self.dataHeight = dataHeight
        self.rmax = sqrt(Double(dataWidth*dataWidth + dataHeight*dataHeight))
        self.houghHeight = Int(rmax*2) // units are rho (pixels)
        self.dr   = 2 * rmax / Double(houghHeight);
        self.dth  = Double.pi / Double(houghWidth);
        self.counts = [[Double]](repeating: [Double](repeating: 0, count: houghHeight),
                                 count: Int(houghWidth))
        self.inputData = inputData
        self.maxValueRange = maxValueRange
    }

    func resetCounts() {
        for (x, row) in self.counts.enumerated() {
            for(y, _) in row.enumerated() {
                counts[x][y] = 0
            }
        }
    }
    
    public func lines(maxCount: Int? = nil, // max number of lines to return
                      minPixelValue: Int16 = 1000, // the dimmest pixel we will process
                      minLineCount: Int = 20)      // lines with counts smaller will not be returned
      -> [Line]
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
                let pixelValue = inputData[(y * dataWidth) + x]

                if pixelValue > minPixelValue {
                    // record all possible lines that transit this pixel
                    for k in 0 ..< Int(houghWidth) {
                        let th = dth * Double(k)
                        let r2 = (Double(x)*cos(th) + Double(y)*sin(th))
                        let iry = Int(rmax + r2/dr)

                        // the value recorded is the brightness of the pixel at this value

                        // what about dimmer lines?  i.e. fast moving low orbit satellites?
                        // may keep two versions of counts, one via pixel value,
                        // the other by the simple existance of a pixel of this value here
                        
                        let newValue = counts[k][iry]+1//Double(pixelValue)
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

                // XXX apply min count?
                
                if !isMax(x: x, y: y, within: maxValueRange) { continue }

                var theta = Double(x)/2.0 // why /2 ?
                var rho = Double(y) - rmax
                
                if(rho < 0) {
                    // keeping rho positive
                    //Log.d("reversing orig rho \(rho) theta \(theta)")
                    rho = -rho
                    theta = (theta + 180).truncatingRemainder(dividingBy: 360)
                }
                let countInt = Int(count)
                if countInt > minLineCount {                                         
                    lines.append(Line(theta: theta, rho: rho, votes: countInt))
                }
            }
        }

        // put higher counts at the front of the list
        let sortedLines = lines.sorted() { $0.votes > $1.votes }

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

    func isMax(x: Int, y: Int, within pixels: Int) -> Bool {
        let count = counts[x][y]

        var leftBorder = x - pixels
        var rightBorder = x + pixels
        var topBorder = y - pixels
        var bottomBorder = y + pixels

        if leftBorder < 0 { leftBorder = 0 }
        if rightBorder > houghWidth { rightBorder = houghWidth }
        if topBorder < 0 { topBorder = 0 }
        if bottomBorder > houghHeight { bottomBorder = houghHeight }

        for y in leftBorder..<rightBorder {
            for z in topBorder..<bottomBorder {
                if counts[y][z] > count { return false }
            }
        }
        return true
    }
}
