import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - try image blending
 - make it faster
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - fix bug where '/' at the end of the command line arg isn't handled well
 - detect idle cpu % and use max cpu% instead of max % of frames
 - maybe just always comare against a single frame? (faster, not much difference?
 - use the number of groups that have fallen into the same line group to boost its painting
 - go async when processing lots of hough transforms on groups
 - add more descriptive coloring to test paint
   - show all outliers
   - make groups of the right size different color
   - somehow color not chosen outliers to say why
 - output dirs are created even when intput filename is not existant
 - exclude outlier groups with minimum bounding box sizes
   most of the non-painted larger outlier groups are nearly square
   lines have a larger aspect ratio
 - get logging to have 'ntar-' at the front (current name is too generic)
*/

Log.handlers = 
[
  .console: ConsoleLogHandler(at: .debug),
  .file: FileLogHandler(at: .debug)
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
                                          maxPixelDistance: 7200, // XXX hardcoded constants
                                          testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

