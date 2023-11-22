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
 done:
   - extract existing validated outlier group information into a single binary image
     where each non-black pixel is one which is part of some outlier group

 
 todo:
   - integrate validated outlier images into main star workflow
     - generate them like the aligned and subtraction images
     - get them into the GUI like the subtraction images
     
   - if a -validated-outlier-images dir exists during processing of a sequence
     with no outliers detected already, use the outlier validation image instead
     of the decision tree to decide paintablility.
     If any pixel of an outlier is marked as paintable in the validation image, 
     mark the outlier as paintable.  Otherwise don't paint.
     
  This will allow for existing validated sequences to be upgraded to newer versions of star
  and to only require a small amount of further validation.  Mostly to mark airplanes which
  were not caught as outlier groups on the previous validation.

  Then we will have a whole lot more validated data with less effort
 */

@main
struct OutlierUpgraderCLI: AsyncParsableCommand {

    @Option(name: [.short, .customLong("input-sequence-dir")], help:"""
        Input dir for outlier groups for a sequence
        """)
    var inputSequenceDir: String

    @Option(name: [.short, .customLong("output-dir")], help:"""
        Output dir for written files
        """)
    var outputDir: String
    
    mutating func run() async throws {

        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)

        Log.i("Hello, Cruel World")

        try await getImageSize()
        try await writeOutlierValidationImage()
    }

    func writeOutlierValidationImage() async throws {
        try await loadAllOutliers() { frameIndex, outlierGroups in
            //Log.d("got frame \(frameIndex) w/ \(outlierGroups.members.count) outliers")
            
            let image = outlierGroups.validationImage
            
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
            Log.d("base_images \(base_images)")
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
        let frame_dirs = try fileManager.contentsOfDirectory(atPath: inputSequenceDir)

        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
            for item in frame_dirs {
                try await taskGroup.addTask() {
                    // every outlier directory is labeled with an integer
                    if let frameIndex = Int(item),
                       let outlierGroups = try await loadOutliers(from: "\(inputSequenceDir)/\(frameIndex)", frameIndex: frameIndex)
                    {
                        closure(frameIndex, outlierGroups)

                        // break here for only one image processed 
                        //if outlierGroups.members.count > 0 { break } // XXX XXX XXX
                    }
                }
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
