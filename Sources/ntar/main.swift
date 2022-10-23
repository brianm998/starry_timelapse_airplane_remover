import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - figure out crashes after hundreds of frames (more threading problems?) (not yet fully fixed)
 - write perl wrapper to keep it running when it crashes (make sure all saved files are ok first?)
 - try image blending
 - make it faster
 - figure out how to parallelize processing of each frame
 - create a direct access pixel object that doesn't copy the value
   make an interface to also allow a mutable one like there is now
   reading pixels out of the base data is time consuming, and unnecessary
 - figure out some way to identify multiple outlier groups that are in a line (hough transform?)
 - fix padding (not sure it still works, could use a different alg)
 - try detecting outlier groups close to eachother by adding padding and re-analyzing
 - do a deep unsafe pointer audit to better understand some difficult to reproduce crashes
   have a good understanding of when and where each image buffer is allocated and released

   https://stackoverflow.com/questions/52420160/ios-error-heap-corruption-detected-free-list-is-damaged-and-incorrect-guard-v
   https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early

   b malloc_error_break

   NSZombieEnabled

   https://www.raywenderlich.com/3089-instruments-tutorial-for-ios-how-to-debug-memory-leaks

 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - detect idle cpu % and use max cpu% instead of max % of frames
 - maybe just always comare against a single frame? (faster, not much difference?
 - loading the layer mask could be faster

   group painting criteria:
     - group size in pix2els 
     - bounding box width, height, aspect ratio and diagonal size
     - percentage of bounding box filled w/ pixels



  group selection plan:

   - make training mode
   - for a frame, give areas and number of expected planes in each area.
     also include areas in which there are no planes or sattelite tracks (ideally milky way too)
   - use this to output a bunch of information about groups that are and are not plane groups
   - include width, height and outlier count for each pland and non plane group
   - build up a big database of known valid plane groups and invalid plane groups (lots of data)
   - write a code generating script which is able to clearly distinguish between the data sets
   - use this big if branch statement in a separate generated .swift file
   - iterate with more data, allowing the re-generation of all data with different max pixel dist

   - try using a histgram of the data distribution across size / fill / aspect ratio to determine
     the likelyhood of a sample belonging to one set of the other.

   - allow exporting of failed detected groups
     - what frame was it on
     - where was it in the frame?
     - an image of it would be ideal, just the outlier pixels within the bounding box


   - next steps:
     - fix test_small_medium, it's not catching the one real plane
     - use that as a test-bed to re-write the image access logic to not use objects
     
*/

Log.handlers = 
[
      .console: ConsoleLogHandler(at: .debug)
    ]


let hough_test = true

typealias Line = (
    theta: Int,                 // angle
    rho: Int,                   // distance
    count: Int
)

if hough_test {
    let filename = "hough_test_image.tif"
    let output_filename = "hough_background.tif"
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

        let paint_it_black = false      
        
        if paint_it_black { // gets rid of the other image data
            for i in 0 ..< CFDataGetLength(output_data as CFData)/8 {
                var nextValue: UInt64 = 0x0000000000000000
                output_data.replaceSubrange(i*8 ..< (i*8)+8, with: &nextValue, count: 8)
            }
        }
        
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
                            let iry = Int(hough_height/2) + Int(r2/dr + 0.5)
                            //Log.d("\(k) \(iry)")
                            let new_value = counts[k][iry]+1
                            counts[k][iry] = new_value
                            if new_value > max_count {
                                max_count = new_value
                            }
                            
                            //Log.d("counts \(counts[k][iry])")
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

            
            var lines: [Line] = [Line](
                repeating: (theta: 0, rho: 0, count: 0),
                count: Int(hough_width * hough_height)
            )

            for (x, row) in counts.enumerated() {
                for (y, _) in row.enumerated() {
                    lines[x * Int(image.width) + y]  = (
                        theta: Int(x/2), // XXX small data loss in conversion
                        rho: y - hough_height/2,
                        count: Int(counts[x][y])
                       )
                }
            }

            // XXX improvement - calculate maxes based upon a 3x3 mask 
            let sortedLines = lines.sorted() { a, b in
                return a.count < b.count
            }
                     
            let small_set_lines = Array<Line>(sortedLines.suffix(20).reversed())

            Log.d("lines \(small_set_lines)")

        }
    } else {
        Log.e("couldn't load image")
    }

                  
} else if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let first_command_line_arg = CommandLine.arguments[1]

    if first_command_line_arg.hasSuffix("/layer_mask.tif") {
        let layer_mask_image_name = first_command_line_arg

        if #available(macOS 10.15, *) {
            if let image = PixelatedImage.getImage(withName: layer_mask_image_name) {
                // this is a data gathering path 

                var parts = first_command_line_arg.components(separatedBy: "/")
                parts.removeLast()
                let path = parts.joined(separator: "/")

                let eraser = KnownOutlierGroupExtractor(layerMask: image,
                                                        imageSequenceDirname: path,
                                                        maxConcurrent: 24,
                                                        maxPixelDistance: 7200,
                                                        padding: 0,
                                                        testPaint: true)

                _ = eraser.readMasks(fromImage: image)
                
                // next step is to refactor group selection work from FrameAirplaneRemover:328
                // into a method, and then override that in KnownOutlierGroupExtractor to
                // use the masks just read to determine what outlier groups are what

                eraser.run()
                
                // inside of a known mask, the largest group is assumed to be airplane
                // verify this visulaly in the test-paint image
                // all other image groups inside any group are considered non-airplane
                // perhaps threshold above 5 pixels or so
                
            } else {
                Log.e("can't load \(layer_mask_image_name)")
            }
        } else {
            Log.e("doh")
        }

    } else {
        // this is the main path
        
        let path = FileManager.default.currentDirectoryPath
        let input_image_sequence_dirname = first_command_line_arg
        // XXX maybe check to make sure this is a directory
        Log.d("will process \(input_image_sequence_dirname)")
        Log.d("on path \(path)")

        if #available(macOS 10.15, *) {
            let dirname = "\(path)/\(input_image_sequence_dirname)"
            let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                                  maxConcurrent: 20,
                                                  maxPixelDistance: 7200,
                                                  padding: 0,
                                                  testPaint: true)
            eraser.run()
        } else {
            Log.d("cannot run :(")
        }
    }
}

