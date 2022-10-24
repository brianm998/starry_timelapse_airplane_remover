import Foundation
import CoreGraphics
import Cocoa


// polar coordinates for right angle intersection with line from origin
typealias Line = (                 
    theta: Double,                 // angle
    rho: Double,                   // distance
    count: Int                     // higher count is better fit for line
)

typealias Coord = (
    x: Int,
    y: Int
)

// this method returns the polar coords for a line that runs through the two given points
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

// returns an array of possible lines in the input data
// lines are returned in polar coords of theta and rho
func lines_from_hough_transform(input_data: [Bool], // indexed by y * data_width + x
                            data_width: Int,
                            data_height: Int,
                            min_count: Int = 5, // lines with less counts than this aren't returned
                            number_of_lines_returned: Int = 20) -> [Line]
{
    Log.d("doing hough transform on input data [\(data_width), \(data_height)]")

    // maximum rho possible
    let rmax = sqrt(Double(data_width*data_width + data_height*data_height))

    Log.d("rmax \(rmax)")

    // y axis is rho, double for negivative values, middle is zero
    let hough_height = Int(rmax*2) // units are rho (pixels)

    // x axis is theta, always 0 to 360
    let hough_width = 360          // units are theta (degrees)
    
    Log.d("hough width \(hough_width) height \(hough_height)")
    
    var counts = [[UInt32]](repeating: [UInt32](repeating: 0, count: hough_height),
                            count: Int(hough_width))
    
    let dr   = 2 * rmax / Double(hough_height);
    let dth  = Double.pi / Double(hough_width);

    // accumulate the hough transform data in counts
    for x in 0 ..< data_width {
        for y in 0 ..< data_height {
            let offset = (y * data_width) + x
            if input_data[offset] {
                // record pixel
                for k in 0 ..< Int(hough_width) {
                    let th = dth * Double(k)
                    let r2 = (Double(x)*cos(th) + Double(y)*sin(th))
                    let iry = Int(rmax + r2/dr)
                    let new_value = counts[k][iry]+1
                    counts[k][iry] = new_value
                }
            }
        }
    }
    
    var lines: [Line] = []

    // grab theta, rho and count values from the transform
    for x in 0 ..< hough_width {
        for y in 0 ..< hough_height {
            var theta = Double(x)/2.0 // why /2 ?
            var rho = Double(y) - rmax
            
            if(rho < 0) {
                // keeping rho positive
                //Log.d("reversing orig rho \(rho) theta \(theta)")
                rho = -rho
                theta = (theta + 180).truncatingRemainder(dividingBy: 360)
            }


            var is_3_x_3_max = true
            let count = counts[x][y]
            if count > 10 {
                Log.d("potential line @ \(x) \(y) has count \(count)")
            }

            // left neighbor
            if x > 0,
               count <= counts[x-1][y]   { is_3_x_3_max = false }

            // left upper neighbor                    
            if x > 0, y > 0,
               count <= counts[x-1][y-1] { is_3_x_3_max = false }

            // left lower neighbor                    
            if x > 0,
               y < hough_height - 1,
               count <= counts[x-1][y+1] { is_3_x_3_max = false }

            // upper neighbor                    
            if y > 0,
               count <= counts[x][y-1]   { is_3_x_3_max = false }

            // lower neighbor                    
            if y < hough_height - 1,
               count <= counts[x][y+1]   { is_3_x_3_max = false }

            // right neighbor
            if x < hough_width - 1,
               count <= counts[x+1][y]   { is_3_x_3_max = false }

            // right upper neighbor                    
            if x < hough_width - 1,
               y > 0,
               count <= counts[x+1][y-1] { is_3_x_3_max = false }

            // right lower neighbor                    
            if x < hough_width - 1,
               y < hough_height - 1,
               count <= counts[x+1][y+1] { is_3_x_3_max = false }
                              
            if is_3_x_3_max {
                Log.i("3x3 max line at (\(x), \(y)) has theta \(theta) rho \(rho) count \(count)")
                lines.append(( 
                             theta: theta,
                             rho: rho,
                             count: Int(count)
                             ))
            }
            
        }
    }
    
    // XXX improvement - calculate based upon a 3x3 mask 
    let sortedLines = lines.sorted() { a, b in
        return a.count < b.count
    }
    
    let small_set_lines = Array<Line>(sortedLines.suffix(number_of_lines_returned).reversed())
    
    Log.d("lines \(small_set_lines)")
    
    for line in small_set_lines {
        let theta = line.theta
        let rho = line.rho
        Log.d("found line with theta \(theta) and dist \(rho) count \(line.count)")
    }
    
    return small_set_lines
}
