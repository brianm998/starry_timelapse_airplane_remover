import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


/*
 This command line utility is designed to read a directory containing a set of already
 validated outlier group specifications for an image sequence, and to output a
 validation image for each frame that contains a non zero pixel for every outlier
 that is considered valid, i.e. a valid subject to paint over.

 These images can then be used to validate outliers discovered with different means.
 */

@main
struct OutlierUpgraderCLI: AsyncParsableCommand {

    @Option(name: [.short, .customLong("input-outliers-dir")], help:"""
        Input dir for outlier groups for a sequence
        """)
    var inputSequenceDir: String

    @Option(name: [.short, .customLong("output-dir")], help:"""
        Output dir for written files
        """)
    var outputDir: String
    
    @Option(name: .shortAndLong, help:"""
        Process a specific frame
        """)
    var frame: Int?
    
    mutating func run() async throws {

        Log.add(handler: ConsoleLogHandler(at: .verbose), for: .console)

        Log.i("Hello, Cruel World")

        try await getImageSize()
        try await writeOutlierValidationImage()
    }

    func writeOutlierValidationImage() async throws {
        try await loadAllOutliers() { frameIndex, outlierGroups in
            if let frame = frame,frame != frameIndex { return }

            //Log.d("got frame \(frameIndex) w/ \(outlierGroups.members.count) outliers")
            
            let image = outlierGroups.validationImage

            // this output frame index has to be incremented by one, because
            // internally the frameIndex is taken from the array index in
            // the image sequence, not the filename.
            // Hence the first frameIndex is always zero.
            // Right now all my image sequences start with 00001
            // internally the filename is preserved and the frameIndex is not exposed
            let outputFilename = "\(outputDir)/\(filename_output_prefix)\(String(format: "%05d", frameIndex+1))\(filename_output_suffix)"
            do {
                try image.writeTIFFEncoding(toFilename: outputFilename)
                //Log.d("wrote \(outputFilename)")
            } catch {
                let message = "could not write \(outputFilename): \(error)"
                Log.e(message)
                fatalError(message)
            }
        }
    }

    var filename_output_prefix: String = "IMG_"
    var filename_output_suffix: String = ".tif"
    
    mutating func getImageSize() async throws {
        if let range: Range<String.Index> = inputSequenceDir.range(of: "-star-v-") {
            let index = inputSequenceDir.distance(from: inputSequenceDir.startIndex,
                                                  to: range.lowerBound)
            let base_dir = String(inputSequenceDir[inputSequenceDir.startIndex..<range.lowerBound])
            Log.d("base_dir '\(base_dir)'")
            let base_images = try fileManager.contentsOfDirectory(atPath: base_dir)
            //Log.d("base_images \(base_images)")
            let filenameRegex = #/^([^\d]+)\d+(.*tiff?)$/#
            for imageName in base_images {
                if let match = imageName.wholeMatch(of: filenameRegex) {
                    filename_output_prefix = String(match.1)
                    filename_output_suffix = String(match.2)

                    if let image = try await PixelatedImage(fromFile: "\(base_dir)/\(imageName)") {
                        IMAGE_WIDTH = Double(image.width)
                        IMAGE_HEIGHT = Double(image.height)
                        break
                    }
                }
            }
        } else {
            throw "cannot get base dir"
        }

        if let IMAGE_WIDTH = IMAGE_WIDTH,
           let IMAGE_HEIGHT = IMAGE_HEIGHT
        {
            Log.i("got image size [\(IMAGE_WIDTH), \(IMAGE_HEIGHT)]")
        } else {
            fatalError("cannot read image size")
        }
    }
    
    func loadAllOutliers(_ closure: @escaping (Int, OutlierGroups) -> Void) async throws {
        var frame_dirs = try fileManager.contentsOfDirectory(atPath: inputSequenceDir)

        frame_dirs.sort { (lhs: String, rhs: String) -> Bool in
            if let int_a = Int(lhs),
               let int_b = Int(rhs)
            {
                let ret = int_a < int_b
                //Log.d("\(int_a) < \(int_b) = \(ret)")
                return ret
            }
            fatalError("SHIT")
            return lhs < rhs
        }

        Log.d("have \(frame_dirs.count) frame_dirs")
        Log.d("frame_dirs \(frame_dirs)")
        
        var previousIndex: Int?
        
        for item in frame_dirs {
            // every outlier directory is labeled with an integer
            do {
                if let frameIndex = Int(item),
                   (self.frame == nil || self.frame == frameIndex),
                   let outlierGroups = try await loadOutliers(from: "\(inputSequenceDir)/\(frameIndex)", frameIndex: frameIndex)
                {
                    //Log.d("frame index \(frameIndex)")
                    if let oldIndex = previousIndex {
                        let diff = frameIndex - oldIndex
                        //Log.d("diff \(diff)")
                        if diff != 1 {
                            Log.e("transition from frame \(oldIndex) to frame \(frameIndex) skipped \(diff) frames!")
                            fatalError("FUCK")
                        }
                        previousIndex = frameIndex
                    } else {
                        previousIndex = frameIndex
                        Log.i("set previousIndex to \(previousIndex)")
                    }
                    
                    closure(frameIndex, outlierGroups)

                    // break here for only one image processed 
                    //if outlierGroups.members.count > 0 { break } // XXX XXX XXX
                }
            } catch {
                Log.e("error: \(error)")
            }
        }
    }
}

func loadOutliers(from dirname: String, frameIndex: Int) async throws -> OutlierGroups? {
    if FileManager.default.fileExists(atPath: dirname) {
        return try await OutlierGroups(at: frameIndex, from: dirname)
    } 
    return nil
}

fileprivate let fileManager = FileManager.default
