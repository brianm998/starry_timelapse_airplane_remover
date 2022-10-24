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

class HoughTransform {

    let data_width: Int
    let data_height: Int
    let rmax: Double            // maximum rho possible

    // y axis is rho, double for negivative values, middle is zero
    let hough_height: Int       // units are rho (pixels)

    // x axis is theta, always 0 to 360
    let hough_width = 360       // units are theta (degrees)

    var input_data: [Bool]
    var counts: [[UInt32]]
    
    let dr: Double
    let dth: Double

    init(data_width: Int, data_height: Int) {
        self.data_width = data_width
        self.data_height = data_height
        self.rmax = sqrt(Double(data_width*data_width + data_height*data_height))
        self.hough_height = Int(rmax*2) // units are rho (pixels)
        self.dr   = 2 * rmax / Double(hough_height);
        self.dth  = Double.pi / Double(hough_width);
        self.counts = [[UInt32]](repeating: [UInt32](repeating: 0, count: hough_height),
                                 count: Int(hough_width))
        self.input_data = [Bool](repeating: false, count: data_width*data_height)
    }

    func resetCounts() {
        for (x, row) in self.counts.enumerated() {
            for(y, _) in row.enumerated() {
                counts[x][y] = 0
            }
        }
    }
    
    func lines(min_count: Int = 5, // lines with less counts than this aren't returned
              number_of_lines_returned: Int = 20,
              x_start: Int = 0,
              y_start: Int = 0,
              x_limit: Int? = nil,
              y_limit: Int? = nil
    ) -> [Line]
    {

        var real_x_limit = self.data_width
        if let x_limit = x_limit { real_x_limit = x_limit }
        
        var real_y_limit = self.data_height
        if let y_limit = y_limit { real_y_limit = y_limit }
        
        // accumulate the hough transform data in counts
        for x in x_start ..< real_x_limit {
            for y in y_start ..< real_y_limit {
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
//                if count > 100 {
                    //Log.d("potential line @ \(x) \(y) has count \(count)")
//                }
                
                // left neighbor
                if x > 0,
                   count <= counts[x-1][y]   { is_3_x_3_max = false }

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
                
                if is_3_x_3_max {
                /* XXX log spew
                    if count > 20 {
                        Log.i("3x3 max line at (\(x), \(y)) has theta \(theta) rho \(rho) count \(count)")
                    }
                */
                    lines.append((theta: theta, rho: rho, count: Int(count)))
                }
            }
        }
        
        let sortedLines = lines.sorted() { a, b in
            return a.count < b.count
        }

        let small_set_lines = Array<Line>(sortedLines.suffix(number_of_lines_returned).reversed())
        
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

