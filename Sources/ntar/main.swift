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
 - fix padding (not sure it still works, could use a different alg)
 - try detecting outlier groups close to eachother by adding padding and re-analyzing
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - fix bug where '/' at the end of the command line arg isn't handled well
 - detect idle cpu % and use max cpu% instead of max % of frames
 - maybe just always comare against a single frame? (faster, not much difference?
 - use 3x3 grid for hough transorm line max count selection
 - use percentages from all sources to determine paintability
 - use the number of groups that have fallen into the same line group to boost its painting

 - try applying hough transformation to bounding boxes of individual outlier groups
   - right now we guess the theta and rho of outlier groups from their bounding boxes
   - instead, use the hough transform on only the outlier group to get theta and rho
   - take the best line because there is only one outlier group
   - use this to determine if the groups fit into the line


   group painting criteria:
     - group size in pixels 
     - bounding box width, height, aspect ratio and diagonal size
     - percentage of bounding box filled w/ pixels
     - group conforms to hough transorm line theta and rho


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
*/

Log.handlers = 
[
      .console: ConsoleLogHandler(at: .debug)
    ]


let hough_test = false

if hough_test {
    // this is for doing direct hough_tests outside the rest of the code
    // convert line between two points on screen into polar coords
    // [276, 0] => [416, 163]
    let (theta, rho) = polar_coords(point1: (x: 276, y: 0),
                                point2: (x: 416, y: 163))
   
    Log.d("theta \(theta) rho \(rho)")

    let filename = "hough_test_image.tif"
    let output_filename = "hough_background.tif"

    hough_test(filename: filename, output_filename: output_filename)
    
} else if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let first_command_line_arg = CommandLine.arguments[1]
        // this is the main path
        
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = first_command_line_arg
    // XXX maybe check to make sure this is a directory
    Log.d("will process \(input_image_sequence_dirname)")
    Log.d("on path \(path)")
    
    if #available(macOS 10.15, *) {
        let dirname = "\(path)/\(input_image_sequence_dirname)"
        let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                          maxConcurrent: 30,
                                          maxPixelDistance: 7200,
                                          padding: 0,
                                          testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

