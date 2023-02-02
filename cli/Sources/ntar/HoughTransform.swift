import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/


// this class does a hough transform on the input_data var into the counts var
// input_data is rows of a matrix of data_width and data_height
// users should input their data into input_data before calling the lines method.
class HoughTransform {

    let data_width: Int
    let data_height: Int
    let rmax: Double            // maximum rho possible

    // y axis is rho, double for negivative values, middle is zero
    let hough_height: Int       // units are rho (pixels)

    // x axis is theta, always 0 to 360
    let hough_width = 360       // units are theta (degrees)

    let max_pixel_distance: UInt16
    
    var input_data: [UInt32]
    var counts: [[Double]]
    
    let dr: Double
    let dth: Double

    convenience init(data_width: Int, data_height: Int, max_pixel_distance: UInt16) {
        self.init(data_width: data_width,
                  data_height: data_height,
                  input_data: [UInt32](repeating: 0, count: data_width*data_height),
                  max_pixel_distance: max_pixel_distance)
    }

    init(data_width: Int, data_height: Int, input_data: [UInt32], max_pixel_distance: UInt16) {
        self.data_width = data_width
        self.data_height = data_height
        self.rmax = sqrt(Double(data_width*data_width + data_height*data_height))
        self.hough_height = Int(rmax*2) // units are rho (pixels)
        self.dr   = 2 * rmax / Double(hough_height);
        self.dth  = Double.pi / Double(hough_width);
        self.counts = [[Double]](repeating: [Double](repeating: 0, count: hough_height),
                                 count: Int(hough_width))
        self.input_data = input_data
        self.max_pixel_distance = max_pixel_distance
    }

    func resetCounts() {
        for (x, row) in self.counts.enumerated() {
            for(y, _) in row.enumerated() {
                counts[x][y] = 0
            }
        }
    }
    
    func lines(min_count: Int = 5, // lines with less counts than this aren't returned
              number_of_lines_returned: Int? = nil) -> [Line]
    {
        //let start_time = NSDate().timeIntervalSince1970

        // accumulate the hough transform data in counts from the input data
        // this can take a long time when there are lots of input points
        for x in 0 ..< self.data_width {
            for y in 0 ..< self.data_height {
                let offset = (y * data_width) + x
                let pixel_value = input_data[offset]
                if pixel_value > max_pixel_distance {
                    // record pixel
                    for k in 0 ..< Int(hough_width) {
                        let th = dth * Double(k)
                        let r2 = (Double(x)*cos(th) + Double(y)*sin(th))
                        let iry = Int(rmax + r2/dr)
                        let new_value = counts[k][iry]+1//Double(pixel_value)
                        // XXX in order to use pixel value properly,
                        // all histograms need to be re-done, and likely
                        // re-evalutated because the current outlier group output data is binary
                        //Log.i("adding pixel value \(pixel_value) to create \(new_value)")
                        counts[k][iry] = new_value
                    }
                }
            }
        }

        //let time_1 = NSDate().timeIntervalSince1970
        //let interval1 = String(format: "%0.1f", time_1 - start_time)
        
        var lines: [Line] = []
        
        // grab theta, rho and count values from the transform
        // this is faster than the loop above by about 5x, depending
        // upon number of points processed above 
        for x in 0 ..< hough_width {
            for y in 0 ..< hough_height {
                let count = counts[x][y]
                if count == 0  { continue }     // ignore cells with no count

                var is_3_x_3_max = true
                
                // left neighbor
                if x > 0,
                   count <= counts[x-1][y]        { is_3_x_3_max = false }
                
                // left upper neighbor                    
                else if x > 0, y > 0,
                        count <= counts[x-1][y-1] { is_3_x_3_max = false }
                
                // left lower neighbor                    
                else if x > 0,
                        y < hough_height - 1,
                        count <= counts[x-1][y+1] { is_3_x_3_max = false }
                
                // upper neighbor                    
                else if y > 0,
                        count <= counts[x][y-1]   { is_3_x_3_max = false }
                
                // lower neighbor                    
                else if y < hough_height - 1,
                        count <= counts[x][y+1]   { is_3_x_3_max = false }
                
                // right neighbor
                else if x < hough_width - 1,
                        count <= counts[x+1][y]   { is_3_x_3_max = false }
                
                // right upper neighbor                    
                else if x < hough_width - 1,
                        y > 0,
                        count <= counts[x+1][y-1] { is_3_x_3_max = false }
                
                // right lower neighbor                    
                else if x < hough_width - 1,
                        y < hough_height - 1,
                        count <= counts[x+1][y+1] { is_3_x_3_max = false }
                
                else if is_3_x_3_max {
                    var theta = Double(x)/2.0 // why /2 ?
                    var rho = Double(y) - rmax
                    
                    if(rho < 0) {
                        // keeping rho positive
                        //Log.d("reversing orig rho \(rho) theta \(theta)")
                        rho = -rho
                        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
                    }
                    
                    lines.append((theta: theta, rho: rho, count: Int(count)))
                }
            }
        }

        //let time_2 = NSDate().timeIntervalSince1970
        //let interval2 = String(format: "%0.1f", time_2 - time_1)
        
        let sortedLines = lines.sorted() { a, b in
            return a.count > b.count
        }

        var small_set_lines: Array<Line> = []
        if let number_of_lines_returned = number_of_lines_returned {
            small_set_lines = Array<Line>(sortedLines.suffix(number_of_lines_returned))
        } else {
            small_set_lines = Array<Line>(sortedLines)
        }
        
        //let time_3 = NSDate().timeIntervalSince1970
        //let interval3 = String(format: "%0.1f", time_3 - time_2)

        //Log.d("done with hough transform - \(interval3)s - \(interval2)s - \(interval1)s")
        
        //Log.d("lines \(small_set_lines)")
        /*
        for line in small_set_lines {
            let theta = line.theta
            let rho = line.rho
            //Log.d("found line with theta \(theta) and dist \(rho) count \(line.count)")
        }
        */
        return small_set_lines
    }        
}

// this method returns the polar coords for a line that runs through the two given points
// not used anymore in the current implementation
func polar_coords(point1: Coord, point2: Coord) -> (theta: Double, rho: Double) {
    
    let dx1 = Double(point1.x)
    let dy1 = Double(point1.y)
    let dx2 = Double(point2.x)
    let dy2 = Double(point2.y)

    let slope = (dy1-dy2)/(dx1-dx2)
    
    let n = dy1 - slope * dx1    // y coordinate at zero x
    let m = -n/slope            // x coordinate at zero y
    
    // length of hypotenuse formed by triangle of (0, 0) - (0, n) - (m, 0)
    let hypotenuse = sqrt(n*n + m*m)
    let theta_radians = acos(n/hypotenuse)     // theta in radians
    
    var theta = theta_radians * 180/Double.pi  // theta in degrees
    var rho = cos(theta_radians) * m          // distance from orgin to right angle with line
    
    if(rho < 0) {
        // keep rho positive
        rho = -rho
        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
    }
    return (theta: theta,  // degrees from the X axis, clockwise
           rho: rho)      // distance to right angle with line from origin in pixels
}

