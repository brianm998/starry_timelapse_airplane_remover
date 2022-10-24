import Foundation
import CoreGraphics
import Cocoa

// this method is used for testing the hough transformation code by itself
func hough_test(filename: String, output_filename: String) {

    // the output filename needs to be exactly the right size
    // specifically hough_height and hough_width
    
    // the hough test
    
    Log.d("Loading image from \(filename)")
    
    if #available(macOS 10.15, *),
       let image = PixelatedImage.getImage(withName: filename),
       let output_image = PixelatedImage.getImage(withName: output_filename)
    {
        let rmax = sqrt(Double(image.width*image.width + image.height*image.height))

        Log.i("rmax \(rmax)")
            
        let hough_height = Int(rmax*2) // units are rho (pixels)
        let hough_width = 360     // units are theta (degrees)

        if hough_height != output_image.height || hough_width != output_image.width {
            Log.e("\(hough_height) != \(output_image.height) || \(hough_width) != \(output_image.width)")
            fatalError("image size mismatch")
        }
        
        Log.e("hough width \(hough_width) height \(hough_height)")
        
        guard var output_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                        CFDataGetLength(output_image.raw_image_data as CFData),
                                                        output_image.raw_image_data as CFData) as? Data
              else { fatalError("fuck") }

        image.read { pixels in 
            var counts = [[UInt32]](repeating: [UInt32](repeating: 0, count: hough_height),
                                    count: Int(hough_width))

            let dr   = 2 * rmax / Double(hough_height);
            let dth  = Double.pi / Double(hough_width);

            var max_count: UInt32 = 0
            
            for x in 0 ..< image.width {
                for y in 0 ..< image.height {
                    let offset = (y * image.width*3) + (x * 3) // XXX hardcoded 3's
                    let orig_red = pixels[offset]
                    let orig_green = pixels[offset+1]
                    let orig_blue = pixels[offset+2]
                    let intensity: UInt64 = UInt64(orig_red) + UInt64(orig_green) + UInt64(orig_blue)
                    if intensity > 0xFF {
                        // record pixel

                        for k in 0 ..< Int(hough_width) {
                            let th = dth * Double(k)
                            let r2 = (Double(x)*cos(th) + Double(y)*sin(th))
                            let iry = Int(rmax + r2/dr)
                            let new_value = counts[k][iry]+1
                            counts[k][iry] = new_value
                            if new_value > max_count {
                                max_count = new_value
                            }
                        }
                    }
                }
            }

            for x in 0 ..< hough_width {
                for y in 0 ..< hough_height {
                    let offset = (Int(y) * output_image.width*6) + (Int(x) * 6)
                    //Log.d("offset \(offset) \(CFDataGetLength(output_data as CFData))")
                    var value = UInt32(Double(counts[x][y])/Double(max_count)*Double(0xFFFF))
                    output_data.replaceSubrange(offset ..< offset+2,
                                                with: &value,
                                                count: 2)
                    output_data.replaceSubrange(offset+2 ..< offset+4,
                                                with: &value,
                                                count: 2)
                    output_data.replaceSubrange(offset+4 ..< offset+6,
                                                with: &value,
                                                count: 2)
                }
            }

            output_image.writeTIFFEncoding(ofData: output_data, toFilename: "hough_transform.tif")

              /*

               done: 
                get the width and height (rho and theta) working right of the output image

              next steps:

                calculate proper rho and theta in calculated output lines
             */          

            
            var lines: [Line] = []

            let min_count = 50  // smaller ones will be ignored
            let number_of_lines_returned = 20 // limit on sorted list of lines
            
            for x in 0 ..< hough_width {
                for y in 0 ..< hough_height {
                    var theta = Double(x)/2.0
                    var rho = Double(y) - rmax

                    if(rho < 0) {
                        // keeping rho positive
                        //Log.d("reversing orig rho \(rho) theta \(theta)")
                        rho = -rho
                        theta = (theta + 180).truncatingRemainder(dividingBy: 360)
                    }
                    let count = counts[x][y]
                    if count >= min_count { // XXX arbitrary
                        Log.i("line at (\(x), \(y)) has theta \(theta) rho \(rho) count \(count)")
                        lines.append(( 
                                     theta: theta, // XXX small data loss in conversion
                                     rho: rho,
                                     count: Int(counts[x][y])
                                     ))
                    }
                    
                }
            }

            // XXX improvement - calculate maxes based upon a 3x3 mask 
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

            // next step is to find the highest counts, and extraplate lines from them

            // then somehow map those back to outlier groups, using bounding pixels
            
        }
    } else {
        Log.e("couldn't load image")
    }
}
