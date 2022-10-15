import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are
 - figure out crashes after hundreds of frames (more threading problems?) (maybe fixed?)
 - write perl wrapper to keep it running when it crashes (make sure all saved files are ok first?)
 - try image blending
 - explore using multi dementional array instead of hash for outliers
 - make it faster
*/

Log.handlers = 
    [
      .console: ConsoleLogHandler(at: .error)
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
                                             maxConcurrent: 35,
                                             minNeighbors: 130,
                                             padding: 0,
                                             testPaint: true)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

