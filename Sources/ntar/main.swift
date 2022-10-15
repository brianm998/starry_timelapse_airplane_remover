import Foundation
import CoreGraphics
import Cocoa

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
                                             minNeighbors: 130)
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

