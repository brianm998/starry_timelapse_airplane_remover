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
        let eraser = NighttimeAirplaneEraser(imageSequenceDirname: "\(path)/\(input_image_sequence_dirname)")
        eraser.run()
    } else {
        Log.d("cannot run :(")
    }
}

