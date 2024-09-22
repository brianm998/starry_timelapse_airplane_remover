import Foundation
import CoreGraphics
import logging
import Cocoa


// XXX move this shit

public func mkdir(_ path: String) {
    if !FileManager.default.fileExists(atPath: path) {
        //Log.e("create directory at path \(path)")
        // XXX this can fail even then the file already exists
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: false,
                                                 attributes: nil)
    }
}

// removes path from filename
public func removePath(fromString string: String) -> String {
    let components = string.components(separatedBy: "/")
    let ret = components[components.count-1]
    return ret
}


