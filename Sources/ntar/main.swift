import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - figure out crashes after hundreds of frames (more threading problems?) (not yet fully fixed)
 - write perl wrapper to keep it running when it crashes (make sure all saved files are ok first?)
 - try image blending
 - explore using multi dementional array instead of hash for outliers
 - make it faster
 - include frame number in logging
 - figure out how to parallelize processing of each frame
 - detect long skinny shape types by longest distance between any two points
   (needs to be all the same feature, not broken up)
 - create a direct access pixel object that doesn't copy the value
   make an interface to also allow a mutable one like there is now
   reading pixels out of the base data is time consuming, and unnecessary
 - add a categorization step for outlier groups after discovery, based upon length and size
*/

Log.handlers = 
    [
      .console: ConsoleLogHandler(at: .debug)
    ]


if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = CommandLine.arguments[1]
    Log.d("will process \(input_image_sequence_dirname)")
    Log.d("on path \(path)")

    if #available(macOS 10.15, *) {
        let dirname = "\(path)/\(input_image_sequence_dirname)"
        let eraser = NighttimeAirplaneRemover(imageSequenceDirname: dirname,
                                              maxConcurrent: 30,
                                              minTrailLength: 40,
                                              // XXX 130 catches some things that aren't airplanes
                                              // XXX 200 misses too many things
                                              padding: 0,
                                              testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

