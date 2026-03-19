import Foundation
import logging


// XXX move this shit

public func mkdir(_ path: String) {
    // Expand ~ and resolve any relative bits
    let expanded = NSString(string: path).expandingTildeInPath

    // Use FileManager to create directory with intermediate directories (like `mkdir -p`)
    do {
        try FileManager.default.createDirectory(atPath: expanded,
                                                withIntermediateDirectories: true,
                                                attributes: nil)
    } catch {
        // Write an error message to stderr (non-throwing function)
        let message = "mkdir: failed to create directory '\(expanded)': \(error.localizedDescription)\n"
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
/*
public func mkdir(_ path: String) {
    if !FileManager.default.fileExists(atPath: path) {
        //Log.e("create directory at path \(path)")
        // XXX this can fail even then the file already exists
        try? FileManager.default.createDirectory(atPath: path,
                                                 withIntermediateDirectories: false,
                                                 attributes: nil)
    }
}*/

// removes path from filename
public func removePath(fromString string: String) -> String {
    let components = string.components(separatedBy: "/")
    let ret = components[components.count-1]
    return ret
}


