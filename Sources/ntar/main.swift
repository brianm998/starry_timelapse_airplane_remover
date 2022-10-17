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
                                              maxConcurrent: 32,
                                              minTrailLength: 40,
                                              // minTrailLength: 50 // no falses, some missed
                                              maxPixelDistance: 7200,
                                              padding: 0,
                                              testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

