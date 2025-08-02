import Foundation
import ShellOut
import logging
import kht_bridge

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 This class alows using panotools via hugin to map the sky from one frame onto another
 */
public class StarAlignment {
    // align_image_stack is bundled with Star directly
    
    // write an output file with the same name as the reference image to the outputDirname
    // the file should be an aligned version of alignmentImageName
    public static func align(_ alignmentImageNames: [Int:String],
                             to referenceImageName: String,
                             inDir outputDirname: String) async throws -> [Int:String]
    {
        Log.d("star align 1 outputDirname \(outputDirname)")
        StarCore.mkdir(outputDirname)
        return try await starAlignmentMonitor.load() { 
            Log.d("star align 2")
            return StarAlignment.alignInt(alignmentImageNames,
                                         to: referenceImageName,
                                         inDir: outputDirname)
        }
    }
    
    private static func alignInt(_ alignmentImageNames: [Int:String],
                                 to referenceImageName: String,
                                 inDir outputDirname: String) -> [Int:String]
    {
        Log.d("doing star alignment of referenceImageName \(referenceImageName) to alignmentImageNames \(alignmentImageNames) in outputDirname \(outputDirname)")
        
        let comps = referenceImageName.components(separatedBy: "/")
        let baseFile = comps[comps.count-1]
        let comps2 = baseFile.components(separatedBy: ".")

        let baseName = comps2[0]
        //let baseExt = comps2[1]
        
        Log.d("baseName \(baseName)")

        let sortedFilenames = sortedValues(from: alignmentImageNames)
        let sortedFrameIndices = sortedKeys(from: alignmentImageNames)

        Log.d("sortedFilenames \(sortedFilenames)")
        
        do {
            var outputFilenames: [Int: String] = [:]
            try ObjC.catchException {
                let args = ["--align-to-first",
                            "--use-given-order",
                            "-a", baseName,
                            referenceImageName] + sortedFilenames
                // first try to run hugin star alignment

                try shellOut(to: ToolPaths.alignImageStack,
                             arguments: args,
                             at: outputDirname)
                Log.d("alignment worked")

                // the first output file is simply a copy of the reference frame, delete it
                try shellOut(to: "rm",
                             arguments: ["\(baseName)0000.tif"],
                             at: outputDirname)
                Log.d("rm worked")


                for (index, alignmentName) in sortedFilenames.enumerated() {

                    if let origFilename = alignmentName.substringAfterLastSlash() {
                        
                        // the other output files are the other images mapped to the base one,
                        // rename them to have the same name as the aligned frame
                        let indexStr = String(format: "%04d", index+1)
                        let frameIndex = sortedFrameIndices[index]
                        Log.d("about to mv \(baseName)\(indexStr).tif \(origFilename) ")
                        try shellOut(to: "mv",
                                     arguments: ["\(baseName)\(indexStr).tif", "\(origFilename)"],
                                     at: outputDirname)
                        Log.d("mv \(baseName)\(indexStr).tif \(outputDirname)/\(origFilename) worked ")
                        outputFilenames[frameIndex] = "\(outputDirname)/\(origFilename)"
                    }
                }
            }
            return outputFilenames
        } catch {
            if let error = error as? ShellOutError {
                Log.e("STDERR: \(error.message)") // log STDERR
                Log.e("STDOUT: \(error.output)")  // log STDOUT
            } else {
                Log.e("\(error)")
            }
            // if the alignment fails, simply hard link them together
            // assuming same volume :(

            if let origFilename = sortedFilenames[0].substringAfterLastSlash() {
            
                let fakeAlignmentName = "\(outputDirname)/\(origFilename)"
                
                do {
                    try ObjC.catchException {
                        try shellOut(to: "ln", arguments: [sortedFilenames[0], fakeAlignmentName])
                    }
                    return [sortedFrameIndices[0]:fakeAlignmentName]
                } catch {

                    if let error = error as? ShellOutError {
                        Log.e("STDERR: \(error.message)") // log STDERR
                        Log.e("STDOUT: \(error.output)")  // log STDOUT
                    } else {
                        Log.e("\(error)")
                    }
                    
                    // ok, the ln failed, try to just cp instead
                    
                    do {
                        try ObjC.catchException {
                            try shellOut(to: "cp", arguments: [sortedFilenames[0], fakeAlignmentName])
                        }
                        return [sortedFrameIndices[0] : fakeAlignmentName]
                    } catch {
                        if let error = error as? ShellOutError {
                            Log.e("STDERR: \(error.message)") // log STDERR
                            Log.e("STDOUT: \(error.output)")  // log STDOUT

                        }
                    }
                }
            }
        }

        Log.e("star alignment totally failed :(")
        
        // we were unsuccessful running the alignment and
        // also both ln and cp from the orig failed :(
        return [:]
    }
}

// XXX make this max a parameter
fileprivate let starAlignmentMonitor = FileSystemMonitor(max: 8) // XXX calculate number of cpus / 4

func sortedValues(from dict: [Int: String]) -> [String] {
    return dict
        .sorted { $0.key < $1.key }   // sort the (key, value) tuples by key
        .map { $0.value }             // extract the values in order
}

func sortedKeys(from dict: [Int: String]) -> [Int] {
    return dict
      .sorted { $0.key < $1.key }   // sort the (key, value) tuples by key
      .map { $0.key }
}
