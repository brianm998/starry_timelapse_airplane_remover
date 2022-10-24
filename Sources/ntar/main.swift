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


let hough_test = false

if hough_test {
    // convert line between two points on screen into polar coords
    // [276, 0] => [416, 163]
    let (theta, rho) = polar_coords(x1: 276, y1: 0, x2: 416, y2: 163)
   
    Log.d("theta \(theta) rho \(rho)")

    let filename = "hough_test_image.tif"
    let output_filename = "hough_background.tif"

//    hough_test(filename: filename, output_filename: output_filename)
    
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
                                                  maxConcurrent: 40,
                                                  maxPixelDistance: 7200,
                                                  padding: 0,
                                                  testPaint: true)
            eraser.run()
        } else {
            Log.d("cannot run :(")
        }
    }
}

