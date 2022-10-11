import Foundation
import Cocoa

if CommandLine.arguments.count < 1 {
    print("need more args!")    // XXX make this better
} else {
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = CommandLine.arguments[1]
    print("will process \(input_image_sequence_dirname)")
    print("on path \(path)")
    let image_files = list_image_files(atPath: "\(path)/\(input_image_sequence_dirname)")
    let images = try load(imageFiles: image_files)
    print("loaded images \(images)")
}

func load(imageFiles: [String]) throws -> [NSImage] {
    var ret: [NSImage] = [];
    try imageFiles.forEach { file in
        let imageURL = NSURL(fileURLWithPath: file, isDirectory: false)
        let data = try Data(contentsOf: imageURL as URL)
        if let image = NSImage(data: data) {
            ret.append(image)
        }
    }
    return ret;
}

func list_image_files(atPath path: String) -> [String] {
    var image_files: [String] = []

    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
        contents.forEach { file in
            if file.hasSuffix(".tif") || file.hasSuffix(".tiff") {
                print("file \(file)")
                image_files.append("\(path)/\(file)")
            }
        }
    } catch {
        print("OH FUCK \(error)")
    }
    return image_files
}

