import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

/*
todo:

 - try image blending
 - make it faster (can always be faster) 
 - still crashes (thankfully not often, and re-start can fix it)
 - make crash detection perl script better
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
 - fix bug where '/' at the end of the command line arg isn't handled well
 - detect idle cpu % and use max cpu% instead of max % of frames
 - use the number of groups that have fallen into the same line group to boost its painting
 - output dirs are created even when intput filename is not existant

 - using too much memory problems :(
   better, but still uses lots of ram

 - specific out of memory issue with initial processing queue overloading the single final processing thread
   use some tool like this to avoid forcing a reboot:
   https://stackoverflow.com/questions/71209362/how-to-check-system-memory-usage-with-swift

 - make a better config system than the hardcoded constants below

*/


// XXX here are some random global constants that maybe should be exposed somehow

// 34 concurrent frames maxes out around 60 gigs of ram usage for 24 mega pixel images

let max_concurrent_frames: UInt = 36  // number of frames to process in parallel about 1 per cpu core
let max_pixel_brightness_distance: UInt16 = 7200 // distance in brightness to be considered an outlier

let min_group_size = 120       // groups smaller than this are ignored
let min_line_count = 20        // lines with counts smaller than this are ignored

let group_min_line_count = 4    // used when hough transorming individual groups
let max_theta_diff: Double = 4  // degrees of difference allowed between lines
let max_rho_diff: Double = 70   // pixels of line displacement allowed
let max_number_of_lines = 8000  // don't process more lines than this per image

let assume_airplane_size = 700 // don't bother spending the time to fully process
                            // groups larger than this, assume we should paint over them

// how far in each direction do we go when doing final processing?
let number_final_processing_neighbors_needed = 4 // in each direction

let final_theta_diff: Double = 5       // how close in theta/rho outliers need to be between frames
let final_rho_diff: Double = 70

let final_group_boundary_amt = 8  // how much we pad the overlap amounts on the final pass


let test_paint = true           // write out a separate image sequence with colors indicating
                              // what was detected, and what was changed.  Helpful for debugging

let hough_test = false


let machine = sysctl(name: "hw.machine")
let memsize = sysctl(name: "hw.memsize")
let foobar = sysctl(name: "hw.ncpu")

Log.d("machine \(machine)")
Log.d("memsize \(memsize)")
Log.d("foobar \(foobar)")


func sysctl(name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    var memsize = [CChar](repeating: 0,  count: size)
    sysctlbyname(name, &memsize, &size, nil, 0)
    return String(cString: memsize)
}

func getMemSize() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    var memsize = [CChar](repeating: 0,  count: size)
    sysctlbyname("hw.machine", &memsize, &size, nil, 0)
    return String(cString: memsize)
}

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
    
} else if CommandLine.arguments.count < 2 {

    Log.d("need more args!")    // XXX make this better
} else {

    let executable_name = remove_path(fromString: CommandLine.arguments[0])
    let first_command_line_arg = CommandLine.arguments[1]
    // this is the main path
        
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = first_command_line_arg

    Log.name = "\(executable_name)-log"
    Log.nameSuffix = input_image_sequence_dirname
    
    Log.handlers = 
    [
      .console: ConsoleLogHandler(at: .debug),
      .file: FileLogHandler(at: .debug)
    ]

    // XXX maybe check to make sure this is a directory
    Log.d("will process \(input_image_sequence_dirname) on path \(path)")

    Log.d("running with min_group_size \(min_group_size) min_line_count \(min_line_count)")
    Log.d("group_min_line_count \(group_min_line_count) max_theta_diff \(max_theta_diff) max_rho_diff \(max_rho_diff)")
    Log.d("max_number_of_lines \(max_number_of_lines) assume_airplane_size \(assume_airplane_size)")
    Log.d("max_concurrent_frames \(max_concurrent_frames) max_pixel_brightness_distance \(max_pixel_brightness_distance)")
    
    if #available(macOS 10.15, *) {
        let dirname = "\(path)/\(input_image_sequence_dirname)"
        let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                          maxConcurrent: max_concurrent_frames,
                                          maxPixelDistance: max_pixel_brightness_distance, 
                                          testPaint: test_paint)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

