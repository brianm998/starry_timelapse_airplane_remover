import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - try image blending
 - make it faster (can always be faster)
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - fix bug where '/' at the end of the command line arg isn't handled well
 - detect idle cpu % and use max cpu% instead of max % of frames
 - maybe just always comare against a single frame? (faster, not much difference?
 - use the number of groups that have fallen into the same line group to boost its painting
 - add more descriptive coloring to test paint
   - show all outliers
   - make groups of the right size different color
   - somehow color not chosen outliers to say why
 - output dirs are created even when intput filename is not existant
 - exclude outlier groups with minimum bounding box sizes
   most of the non-painted larger outlier groups are nearly square
   lines have a larger aspect ratio
 - get logging to have 'ntar-' at the front (current name is too generic)
 - be alble to name log file after first arg
 - identify is outlier group is a line by the size of the group vs the count of the highest line?
 - allow tracking of detected lines across multiple frames, and use that to keep them out
 - try smaller min_group_size to get more satelites.
 - try populating the full outlier hough data with all outliers, not just larger ones
   too much noise?  may make separated segments record better lines
   maybe just try reducing the min_group_size when generating the hough data?
*/

Log.handlers = 
[
  .console: ConsoleLogHandler(at: .debug),
  .file: FileLogHandler(at: .debug)
]


// XXX here are some random global constants that maybe should be exposed somehow
let max_concurrent_frames: UInt = 30  // number of frames to process in parallel about 1 per cpu core
let max_pixel_brightness_distance: UInt16 = 7200 // distance in brightness to be considered an outlier

let min_group_size = 120       // groups smaller than this are ignored
let min_line_count = 50        // lines with counts smaller than this are ignored

let group_min_line_count = 4    // used when hough transorming individual groups
let max_theta_diff: Double = 4  // degrees of difference allowed between lines
let max_rho_diff: Double = 12   // pixels of line displacement allowed
let max_number_of_lines = 70    // don't process more lines than this per image

let assume_airplane_size = 800  // don't bother spending the time to fully process
                             // groups larger than this, assume we should paint over them



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
    Log.d("will process \(input_image_sequence_dirname) on path \(path)")

    Log.d("running with min_group_size \(min_group_size) min_line_count \(min_line_count) group_min_line_count \(group_min_line_count) max_theta_diff \(max_theta_diff) max_rho_diff \(max_rho_diff) max_number_of_lines \(max_number_of_lines) assume_airplane_size \(assume_airplane_size) max_concurrent_frames \(max_concurrent_frames) max_pixel_brightness_distance \(max_pixel_brightness_distance)")
    
    if #available(macOS 10.15, *) {
        let dirname = "\(path)/\(input_image_sequence_dirname)"
        let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                          maxConcurrent: max_concurrent_frames,
                                          maxPixelDistance: max_pixel_brightness_distance, 
                                          testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

