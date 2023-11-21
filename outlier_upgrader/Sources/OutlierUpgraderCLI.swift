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

 two modes:
   - extract existing validated outlier group information into a single binary image
     where each non-black pixel is one which is part of some outlier group

   - go over a newly assembled group of outlier groups for a previously validated sequence
     set new outlier groups to paint or not paint based upon their overlap with pixels
     on the validated image produced above

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
            Log.d("got frame \(frameIndex) w/ \(outlierGroups.members.count) outliers")

            // create base image data array
            var baseData = [UInt16](repeating: 0, count: Int(IMAGE_WIDTH!*IMAGE_HEIGHT!))

            // write into this array from the pixels in this group
            for (groupName, group) in outlierGroups.members {
                for x in 0 ..< group.bounds.width {
                    for y in 0 ..< group.bounds.height {
                        if group.pixels[y*group.bounds.width+x] != 0 {
                            let imageX = x + group.bounds.min.x
                            let imageY = y + group.bounds.min.y
                            baseData[imageY*Int(IMAGE_WIDTH!)+imageX] = 0xFFFF
                        }
                    }
                }
            }

            let outputFilename = "\(outputDir)/IMG_\(String(format: "%05d", frameIndex)).tiff"
            do {
                try save16BitMonoImageData(baseData, to: outputFilename)
                Log.d("wrote \(outputFilename)")
            } catch {
                Log.e("could not write \(outputFilename): \(error)")
            }
        }
    }

    func getImageSize() async throws {
        if let range: Range<String.Index> = inputSequenceDir.range(of: "-star-v-") {
            let index = inputSequenceDir.distance(from: inputSequenceDir.startIndex,
                                                  to: range.lowerBound)
            let base_dir = String(inputSequenceDir[inputSequenceDir.startIndex..<range.lowerBound])
            
            let base_images = try fileManager.contentsOfDirectory(atPath: base_dir)
            for imageName in base_images {
                if imageName.hasSuffix(".tif") || imageName.hasSuffix(".tiff") {

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
                    if let frameIndex = Int(item),
                       let outlierGroups = try await loadOutliers(from: "\(inputSequenceDir)/\(frameIndex)", frameIndex: frameIndex)
                    {
                        closure(frameIndex, outlierGroups)
                    }
                }
            }
        }
    }

    private func save16BitMonoImageData(_ inputPixels: [UInt16],
                                        to filename: String) throws -> PixelatedImage
    {
        let imageData = inputPixels.withUnsafeBufferPointer { Data(buffer: $0) }

        let image = PixelatedImage(width: Int(IMAGE_WIDTH!),
                                   height: Int(IMAGE_HEIGHT!),
                                   rawImageData: imageData,
                                   bitsPerPixel: 16,
                                   bytesPerRow: 2*Int(IMAGE_WIDTH!),
                                   bitsPerComponent: 16,
                                   bytesPerPixel: 2,
                                   bitmapInfo: .byteOrder16Little, 
                                   pixelOffset: 0,
                                   colorSpace: CGColorSpaceCreateDeviceGray(),
                                   ciFormat: .L16)
        
        try image.writeTIFFEncoding(toFilename: filename)

        return image
    }
}

func loadOutliers(from dirname: String, frameIndex: Int) async throws -> OutlierGroups? {
    if FileManager.default.fileExists(atPath: dirname) {
        return try await OutlierGroups(at: frameIndex, from: dirname)
    } 
    return nil
}

fileprivate let fileManager = FileManager.default
