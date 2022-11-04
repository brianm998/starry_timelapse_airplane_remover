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
 - make sure it doesn't still crash (after last actor refactor it hasn't yet)
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

 - look for existing file before painting
   minor help when restarting after a crash, frames that need to be re-calculated but already exist
   number_final_processing_neighbors_needed before the last existing one.

 - XXX this mofo needs to be run in the same dir as the first passed arg :(  FIX THAT

 - group distance calculation isn't right, can cause errors with slow moving objects

 - fix false positive airplanes (causes stars to twinkle)

 - detect outliers across more than 3 frames?
   take average across all adjecent frames, and compare that with value at processing frame

 - try some kind of processing of individual groups that classifies them as plane or not
   either a hough transform to detect that it's cloas to a line, or detecting holes in them?
   i.e. the percentage of neighbors found, or the percentage without empty neighbors

 - restrict final pass processing to more uncertain choices (40%-60% initial score)?

 - use distance between frames when calculating positive final pass too.
   i.e. they shouldn't overlap, but shouldn't be too far away either

 - maybe a bug where last frame is identical to the previous frame for some reason

 - airplanes have:
   - a real line
   - often close but not too far from aligning line in adjecent frames
   - often have lots of pixels
   - pixels more likely to be packed closely together
   - if close to 1-1 aspect ratio, low fill amount
   - if close to line aspect ratio, high fill amount

 - non airplanes have:
   - fewer pixels
   - no real line
   - many holes in the structure
   - unlikely to have matching aligned groups in adjecent frames
   - same approx fill amount regardless of aspect ratio
*/


// XXX here are some random global constants that maybe should be exposed somehow

// 34 concurrent frames maxes out around 60 gigs of ram usage for 24 mega pixel images

let max_concurrent_frames: UInt = 22  // number of frames to process in parallel about 1 per cpu core
let max_pixel_brightness_distance: UInt16 = 8500 // distance in brightness to be considered an outlier

let min_group_size = 150       // groups smaller than this are ignored
let min_line_count = 20        // lines with counts smaller than this are ignored

let group_min_line_count = 4    // used when hough transorming individual groups
let max_theta_diff: Double = 4  // degrees of difference allowed between lines
let max_rho_diff: Double = 70   // pixels of line displacement allowed
let max_number_of_lines = 500  // don't process more lines than this per image

let assume_airplane_size = 1000 // don't bother spending the time to fully process
                            // groups larger than this, assume we should paint over them

// how far in each direction do we go when doing final processing?
let number_final_processing_neighbors_needed = 2 // in each direction

let final_theta_diff: Double = 5       // how close in theta/rho outliers need to be between frames
let final_rho_diff: Double = 70

let final_group_boundary_amt = 1  // how much we pad the overlap amounts on the final pass

let group_number_of_hough_lines = 10 // document this

let final_adjecent_edge_amount: Double = -2 // the spacing allowed between groups in adjecent frames

let final_center_distance_multiplier = 8 // document this

// 0.5 gets lots of lines and no false positives
let looks_like_a_line_lowest_count_reduction: Double = 0.55 // 0-1 percentage of decrease on group_number_of_hough_lines count

let test_paint = true           // write out a separate image sequence with colors indicating
                              // what was detected, and what was changed.  Helpful for debugging

let hough_test = false

let distance_test = false

if distance_test {

    // (1523 1764),  (1611 1780)

    // (2004 1850),  (2126 1879)
    let distance_bewteen_groups =
        edge_distance(min_1_x: 1523,
                 min_1_y: 1764,
                 max_1_x: 1611,
                 max_1_y: 1780,
                 min_2_x: 2004,
                 min_2_y: 1850,
                 max_2_x: 2126,
                 max_2_y: 1879)
    Log.d("distance_bewteen_groups \(distance_bewteen_groups)")

    // (1770 1805),  (1959 1842)
    // (2004 1850),  (2126 1879)
    let distance_bewteen_groups_1 =
        edge_distance(min_1_x: 1770,
                 min_1_y: 1805,
                 max_1_x: 1959,
                 max_1_y: 1842,
                 min_2_x: 2004,
                 min_2_y: 1850,
                 max_2_x: 2126,
                 max_2_y: 1879)
    Log.d("distance_bewteen_groups_1 \(distance_bewteen_groups_1)")

    // (3036 881),  (3143 996)
    // (2837 664),  (2933 765)
    let distance_bewteen_groups_2 =
        edge_distance(min_1_x: 3036,
                 min_1_y: 881,
                 max_1_x: 3143,
                 max_1_y: 996,
                 min_2_x: 2837,
                 min_2_y: 664,
                 max_2_x: 2933,
                 max_2_y: 765)

    Log.d("distance_bewteen_groups_2 \(distance_bewteen_groups_2)")

    // these two do slightly overlap in y, but not in x
    //(1859 1842),  (1979 1887)
    //(1753 1885),  (1858 1925)
    let distance_bewteen_groups_3 =
        edge_distance(min_1_x: 1859,
                 min_1_y: 1842,
                 max_1_x: 1979, 
                 max_1_y: 1887,
                 min_2_x: 1753,
                 min_2_y: 1885,
                 max_2_x: 1858,
                 max_2_y: 1925)

    Log.d("distance_bewteen_groups_3 \(distance_bewteen_groups_3)")

    //(1339 2055),  (1390 2075)
    //(2853 1441),  (2906 1470)
    let distance_bewteen_groups_4 =
        edge_distance(min_1_x: 1339,
                 min_1_y: 2055,
                 max_1_x: 1390,
                 max_1_y: 2075,
                 min_2_x: 2853,
                 min_2_y: 1441,
                 max_2_x: 2906,
                 max_2_y: 1470)

    Log.d("distance_bewteen_groups_4 \(distance_bewteen_groups_4)")
    fatalError("test")
}


let machine = sysctl(name: "hw.machine")
let memsize = sysctl(name: "hw.memsize") // returns empty string :(
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

