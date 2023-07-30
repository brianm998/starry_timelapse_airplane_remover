import Foundation
import ShellOut

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public class StarAlignment {
    public static let pathToBinary = "/Applications/Hugin/Hugin.app/Contents/MacOS"
    public static let binaryName = "align_image_stack"

    // write an output file with the same name as the baseImage to the outputDirname
    // the file should be an aligned version of otherImageName to baseImageName
    public static func align(baseImageName: String,
                             otherImageName: String,
                             outputDirname: String) -> String? {

        let comps = baseImageName.components(separatedBy: "/")
        let baseFile = comps[comps.count-1]
        let comps2 = baseFile.components(separatedBy: ".")

        let baseName = comps2[0]
        let baseExt = comps2[1]

        Log.d("baseName \(baseName)")
        let outputFilename = "\(outputDirname)/\(baseName).\(baseExt)"

        if fileManager.fileExists(atPath: outputFilename) {
            return outputFilename
        }
        
        do {
            // first try to run hugin star alignment 
            try shellOut(to: "\(StarAlignment.pathToBinary)/\(StarAlignment.binaryName)",
                         arguments: ["--use-given-order", "-a", baseName,
                                     baseImageName, otherImageName],
                         at: outputDirname)
            Log.d("alignment worked")

            // the first output file is simply a copy of the reference frame, delete it
            try shellOut(to: "rm",
                         arguments: ["\(baseName)0000.tif"],
                         at: outputDirname)
            Log.d("rm worked")

            // the second output file is the other image mapped to the base one, rename
            // it to have the same name as the base name, it will live in a different dir
            try shellOut(to: "mv",
                         arguments: ["\(baseName)0001.tif",
                                     "\(baseName).\(baseExt)"],
                         at: outputDirname)
            Log.d("mv worked")

            return outputFilename
        } catch {
            if let error = error as? ShellOutError {
                Log.e("STDERR: \(error.message)") // Log.Ds STDERR
                Log.e("STDOUT: \(error.output)")  // Log.Ds STDOUT
            } else {
                Log.e("\(error)")
            }
            // if the alignment fails, simply hard link them together
            // assuming same volume :(
            do {
                try shellOut(to: "ln", arguments: [baseImageName, outputFilename])
                return outputFilename
            } catch {
                if let error = error as? ShellOutError {
                    Log.e("STDERR: \(error.message)") // Log.Ds STDERR
                    Log.e("STDOUT: \(error.output)")  // Log.Ds STDOUT
                } else {
                    Log.e("\(error)")
                }
            }
        }

        // we were unsuccessful both running the alignment and also trying to ln the orig :(
        return nil
    }
}

fileprivate let fileManager = FileManager.default
