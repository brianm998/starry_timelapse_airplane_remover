import Foundation

if CommandLine.arguments.count < 1 {
    print("need more args!")    // XXX make this better
} else {
    let input_image_sequence_dirname = CommandLine.arguments[1]
    let path = FileManager.default.currentDirectoryPath
    print("will process \(input_image_sequence_dirname)")
    print("on path \(path)")
}


