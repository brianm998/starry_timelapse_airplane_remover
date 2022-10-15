import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - figure out crashes after hundreds of frames (more threading problems?)
 - write perl wrapper to keep it running when it crashes (make sure all saved files are ok first?)
 - refactor ImageSequence to be more generic (try to image blend w/ it)
 - allow writing out test paint and normal files to separate output dirs
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
        let eraser = NighttimeAirplaneEraser(imageSequenceDirname: dirname,
                                             maxConcurrent: 40,
                                             minNeighbors: 130,
                                             padding: 0,
                                             testPaint: false)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

