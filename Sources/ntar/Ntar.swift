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
 - make sure it doesn't still crash - after last actor refactor it has only crashed twice :(
   look into actor access to properties, should those be wrapped in methods and not exposed?
 - make crash detection perl script better
 - add scripts to allow video to processed video in one command
   - decompress existing video w/ ffmpeg (and note exactly how it was compressed)
   - process image sequence with ntar
   - recompress processed image sequence w/ ffmpeg with same parameters as before
   - remove image sequence dir
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

 - try some kind of processing of individual groups that classifies them as plane or not
   either a hough transform to detect that it's cloas to a line, or detecting holes in them?
   i.e. the percentage of neighbors found, or the percentage without empty neighbors

 - restrict final pass processing to more uncertain choices (40%-60% initial score)?

 - use distance between frames when calculating positive final pass too.
   i.e. they shouldn't overlap, but shouldn't be too far away either

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
   
 - make the info logging better

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

 - next steps for improving airplane detection:
   - false positive airplanes on stars in (largely in corners is a problem)
     they're yellow, not sure why the overlap detection didn't get them (theta/rho mismatch?).

 - make outlier output text files be separated by airplane / not airplane

 - apply the same center theta outlier logic to outliers within the same frame

 - attempt to reduce false positives by applying .looksLikeALine values to streaks
   i.e. don't trush the theta from hough transform when looksLikeALine score is low

 - find some way to ignore groups on the horizon, it's a problem for moving timelapses,
   can cause the background to skip badly
 
 - figure out how distribution works
   - a .dmg file with a command line installer?  any swift command line installer examples?

 - there is a logging bug where both console and file need to be set to debug, otherwise the logfile
   is not accurate (has some debug, but not all)
 */

// this is here so that PaintReason can see it
var assume_airplane_size: Int = 5000 // don't bother spending the time to fully process

// XXX here are some random global constants that maybe should be exposed somehow

let medium_hough_line_score: Double = 0.4 // close to being a line, not really far

// how far in each direction do we go when doing final processing?
let number_final_processing_neighbors_needed = 3 // in each direction

let final_theta_diff: Double = 10       // how close in theta/rho outliers need to be between frames
let final_rho_diff: Double = 20        // 20 works

let center_line_theta_diff: Double = 25 // used in outlier streak detection 

let supported_image_file_types = [".tif", ".tiff"] // XXX move this out

// XXX use this to try to avoid running out of memory somehow
// maybe determine megapixels of images, and guestimate usage and
// avoid spawaning too many threads?
let memory_size_bytes = ProcessInfo.processInfo.physicalMemory
let memory_size_gigs = ProcessInfo.processInfo.physicalMemory/(1024*1024*1024)

let ntar_version = "0.0.7"

// 0.0.2 added more detail group hough transormation analysis, based upon a data set
// 0.0.3 included the data set analysis to include group size and fill, and to use histograms
// 0.0.4 included .inStreak final processing
// 0.0.5 added pixel overlap between outlier groups
// 0.0.6 fixed streak processing and added another layer afterwards
// 0.0.7 really fixed streak processing and lots of refactoring


@main
struct Ntar: ParsableCommand {

    @Option(name: [.customShort("c"), .customLong("console-log-level")], help:"""
        The logging level that ntar will output directly to the terminal.
        """)
    var terminalLogLevel: Log.Level = .info

    @Option(name: [.short, .customLong("file-log-level")], help:"""
        If present, ntar will output a file log at the given level.
        """)
    var fileLogLevel: Log.Level?
    
    @Option(name: [.customShort("b"), .long], help: """
        The percentage in brightness increase necessary for a pixel to be considered an outlier.
        Higher values the number and size of found outlier groups.
        Lower values increase the size and number of outlier groups,
        which may find more airplanes, but also may yield more false positives,
        usually making stars twinkle.
        """)
    var outlierBrightnessThreshold: Double = 12.9


    @Option(name: .shortAndLong, help: """
        The minimum outlier group size.  Outlier groups smaller than this will be ignored.
        Smaller values produce more groups, which may get more small airplane streaks,
        but also might end with more twinkling stars.
        """)
    var minGroupSize: Int = 130        // groups smaller than this are ignored

    @Option(name: .shortAndLong, help: """
        Outlier groups larger than this are assumed to be airplanes, and painted over.
        """)
    var assumeAirplaneSize: Int = assume_airplane_size
    
    @Option(name: .shortAndLong, help: """
        Max Number of frames to process at once.
        The default of all cpus but one works good in most cases.
        May need to be reduced to a lower value if ram consumption is problematic.
        """)
    var numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount-1

    @Flag(name: [.short, .customLong("test-paint")], help:"""
        Write out a separate image sequence with colors indicating
        what was detected, and what was changed.
        Shows what changes have been made to each frame.
        """)
    var test_paint = false

    @Flag(name: [.short, .customLong("show-test-paint-colors")],
          help:"Print out what the test paint colors mean")
    var show_test_paint_colors = false

    @Flag(name: [.customShort("w"), .customLong("write-outlier-group-files")],
          help:"Write individual outlier group image files")
    var should_write_outlier_group_files = false

    @Flag(name: .shortAndLong, help:"Show version number")
    var version = false

    @Flag(name: .customShort("q"),
          help:"process individual outlier group image files")
    var process_outlier_group_images = false

    @Argument(help: """
        Image sequence dirname to process. 
        Should include a sequence of 16 bit tiff files, sortable by name.
        """)
    var image_sequence_dirname: String?

    mutating func run() throws {

        assume_airplane_size = assumeAirplaneSize
        
        if version {
            print("""
                  Nighttime Timelapse Airplane Remover (ntar) version \(ntar_version)
                  """)
            return
        }
        
        if show_test_paint_colors {
            print("""
                  When called with -t or --test-paint, ntar will output two sequences of images.
                  The first will be the normal output with airplanes removed.
                  The second will the the 'test paint' version,
                  where each outlier group larger than \(self.minGroupSize) pixels that will be painted over is painted:

                  """)
            for willPaintReason in PaintReason.shouldPaintCases {
                print("   "+willPaintReason.BasicColor+"- "+willPaintReason.BasicColor.name() +
                      ": "+willPaintReason.name+BasicColor.reset +
                      "\n     \(willPaintReason.description)")
            }
            print("""

                  And each larger outlier group that is not painted over in the normal output is painted:

                  """)
            for willPaintReason in PaintReason.shouldNotPaintCases {
                print("   "+willPaintReason.BasicColor+"- "+willPaintReason.BasicColor.name() +
                      ": "+willPaintReason.name+BasicColor.reset +
                      "\n     \(willPaintReason.description)")
            }
            print("\n")
            return
        } 

        if process_outlier_group_images {
            let airplanes_group = "outlier_data/airplanes"
            let non_airplanes_group = "outlier_data/non_airplanes"
            
            process_outlier_groups(dirname: airplanes_group)
            process_outlier_groups(dirname: non_airplanes_group)
            
            return
        }
        
        if var input_image_sequence_dirname = image_sequence_dirname {

            while input_image_sequence_dirname.hasSuffix("/") {
                // remove any trailing '/' chars,
                // otherwise our created output dir(s) will end up inside this dir,
                // not alongside it
                _ = input_image_sequence_dirname.removeLast()
            }
            
            Log.name = "ntar-log"
            Log.nameSuffix = input_image_sequence_dirname

            Log.handlers[.console] = ConsoleLogHandler(at: terminalLogLevel)
            if let fileLogLevel = fileLogLevel {
                Log.handlers[.file] = FileLogHandler(at: fileLogLevel)
            }
            
            // XXX maybe check to make sure this is a directory
            Log.d("will process \(input_image_sequence_dirname)")
            
            //Log.d("running with min_group_size \(self.minGroupSize) min_line_count \(min_line_count)")
            Log.d("assume_airplane_size \(assume_airplane_size)")
            //Log.d("max_concurrent_frames \(max_concurrent_frames) outlier_brightness_gap \(outlier_brightness_gap)")
            
            if #available(macOS 10.15, *) {
                let eraser = NighttimeAirplaneRemover(imageSequenceDirname: input_image_sequence_dirname,
                                                      maxConcurrent: UInt(numConcurrentRenders),
                                                      maxPixelDistance: outlierBrightnessThreshold,
                                                      minGroupSize: minGroupSize,
                                                      assumeAirplaneSize: assume_airplane_size,
                                                      testPaint: test_paint,
                                                      writeOutlierGroupFiles: should_write_outlier_group_files)
                
                eraser.run()
            } else {
                Log.e("cannot run :(") // XXX make this better
            }
        } else {
            throw ValidationError("need to provide input")
        }
    }
}

// this method reads all the outlier group text files
// and (if missing) generates a csv file with the hough transform data from it
func process_outlier_groups(dirname: String) {
    do {
        let dispatchGroup = DispatchGroup()
        let contents = try file_manager.contentsOfDirectory(atPath: dirname) 
        contents.forEach { file in
            if file.hasSuffix("txt") {

                let base = (file as NSString).deletingPathExtension
                let csv_filename = "\(dirname)/\(base).csv"

                if !file_manager.fileExists(atPath: csv_filename) {
                    dispatchGroup.enter()
                    dispatchQueue.async {
                        do {
                            let contents = try String(contentsOfFile: "\(dirname)/\(file)")
                            let rows = contents.components(separatedBy: "\n")
                            let height = rows.count
                            let width = rows[0].count
                            let houghTransform = HoughTransform(data_width: width, data_height: height)
                            Log.d("size [\(width), \(height)]")
                            for y in 0 ..< height {
                                for (x, char) in rows[y].enumerated() {
                                    if char == "*" {
                                        houghTransform.input_data[y*width + x] = true
                                    }
                                }
                            }
                            let lines = houghTransform.lines(min_count: 1,
                                                             number_of_lines_returned: 100000)
                            var csv_line_data: String = "";
                            lines.forEach { line in
                                csv_line_data += "\(line.theta),\(line.rho),\(line.count)\n"
                            }
                            if let data = csv_line_data.data(using: .utf8) {
                                file_manager.createFile(atPath: csv_filename, contents: data, attributes: nil)
                            }
                        } catch {
                            Log.e(error)
                        }
                        dispatchGroup.leave()
                    } 
                }
            } 
        }
        dispatchGroup.wait()
    } catch {
        Log.e(error)
    }
}


let file_manager = FileManager.default
