import Foundation
import ArgumentParser
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

 - try some kind of processing of individual groups that classifies them as plane or not
   either a hough transform to detect that it's cloas to a line, or detecting holes in them?
   i.e. the percentage of neighbors found, or the percentage without empty neighbors

 - restrict final pass processing to more uncertain choices (40%-60% initial score)?

 - use distance between frames when calculating positive final pass too.
   i.e. they shouldn't overlap, but shouldn't be too far away either

 - expand group hough transform analysis for looksLikeALine to beyond first vs last count value
   currently works remarkedly well considering how crude it is.
   airplanes have a fast drop off after the first few lines, with more lines for larger groups
   non-airplanes have a smoother distribution across the first set of lines

 - expand final processing to identify nearby groups that should be painted
   for example one frame has a known line, and next frame has another group
   w/ similar theta/rho that is not painted, but is the same object

 - perhaps identify smaller groups that are airplanes by % of solidness?
   i.e. no missing pixels in the middle
   oftentimes airplane streaks close to the horizon don't register as lines via hough transform
   because they are too wide and not long enough.  But they are usually solid.

 - false positives are lower now, but still occur sometimes
   try fixing PaintReason.goodScore cases
   perhaps better single group hough transform analysis?
   look at more lines and the distribution of them
   
 - try re-writing the logic that uses the full hough transform to not need it
   use the group hough transforms with more advanced analysis of the data
   look a things like how solid the groups are as well (i.e. no holes)

 - have a method to write out each outlier group as a small b/w image for training purposes

 - use https://github.com/apple/swift-argument-parser

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
let looks_like_a_line_lowest_count_reduction: Double = 0.5 // 0-1 percentage of decrease on group_number_of_hough_lines count

let supported_image_file_types = [".tif", ".tiff"] // XXX move this out
    
let test_paint = true           // write out a separate image sequence with colors indicating
                              // what was detected, and what was changed.  Helpful for debugging

@main
struct Ntar: ParsableCommand {

    @Option(name: .shortAndLong, help: """
Max Number of frames to process at once.
One per cpu works good.
May need to be reduced to a lower value:
 - when processing large images (>24mp)
 - on a machine without gobs of ram (<128g)

""")
    var numConcurrentRenders: Int     // XXX default this to n-cpu


    @Flag(name: .shortAndLong, help:"""
Write out a separate image sequence with colors indicating
what was detected, and what was changed.
Shows what changes have been made to each frame.

""")
    var test_paint = false

    @Argument(help: """
Image sequence dirname to process.
Should include a sequence of 16 bit tiff files, sortable by name.
""")
    var image_sequence_dirname: String

    mutating func run() throws {
    
        // XXX don't assume the arg is in cwd
        let path = FileManager.default.currentDirectoryPath
        let input_image_sequence_dirname = image_sequence_dirname
    
        Log.name = "ntar-log"
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
        //Log.d("max_concurrent_frames \(max_concurrent_frames) max_pixel_brightness_distance \(max_pixel_brightness_distance)")
        
        if #available(macOS 10.15, *) {
            let dirname = "\(path)/\(input_image_sequence_dirname)"
            let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                              maxConcurrent: UInt(numConcurrentRenders),
                                              maxPixelDistance: max_pixel_brightness_distance, 
                                              testPaint: test_paint)
                                                  
            eraser.run()
        } else {
            Log.d("cannot run :(")
        }
    }
}

