import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 Methods used by the FrameAirplaneRemover to save things to file

 Images, outlier groups, etc.
 
 */
extension FrameAirplaneRemover {

    internal func writeValidationImage() {

        guard config.writeFramePreviewFiles ||
              config.writeFrameThumbnailFiles
        else {
            return
        }
        
        guard let outlierGroups = outlierGroups else {
            Log.w("cannot out write nil outlier groups")
            return
        }
        
        let image = outlierGroups.validationImage
        do {
            if !fileManager.fileExists(atPath: self.validationImageFilename) {
                try image.writeTIFFEncoding(toFilename: self.validationImageFilename)
                Log.d("wrote \(self.validationImageFilename)")
            } else {
                Log.i("cannot write validation image to \(self.validationImageFilename), it already exists")
            }

            if let previewImage = image.baseImage(ofSize: self.previewSize),
               let imageData = previewImage.jpegData
            {
                let filename = self.validationImagePreviewFilename
                
                if !fileManager.fileExists(atPath: filename) {
                    fileManager.createFile(atPath: filename,
                                           contents: imageData,
                                           attributes: nil)
                    Log.d("wrote \(self.validationImagePreviewFilename)")
                } else {
                    Log.i("cannot write validation image preview to \(self.validationImagePreviewFilename) because it already exists")
                }
            }
            
            //Log.d("wrote \(outputFilename)")
        } catch {
            let message = "could not write \(outputFilename): \(error)"
            Log.e(message)
        }
    }
    
    internal func writeUprocessedPreviews(_ image: PixelatedImage) {
        if config.writeFramePreviewFiles ||
           config.writeFrameThumbnailFiles
        {
            Log.d("frame \(self.frameIndex) doing preview")
            if let baseImage = image.baseImage {
                // maybe write previews
                // these are not overwritten as the original
                // is assumed to be not change
                self.writePreviewFile(baseImage)
                self.writeThumbnailFile(baseImage)
            } else {
                Log.w("frame \(self.frameIndex) NO BASE IMAGE")
            }
        }
    }

    internal func writeSubtractionPreview(_ image: PixelatedImage) throws {
        if !fileManager.fileExists(atPath: self.alignedSubtractedPreviewFilename) {
            if let processedPreviewImage = image.baseImage(ofSize: self.previewSize),
               let imageData = processedPreviewImage.jpegData
            {
                let filename = self.alignedSubtractedPreviewFilename

                if fileManager.fileExists(atPath: filename) {
                    Log.i("overwriting already existing processed preview \(filename)")
                    try fileManager.removeItem(atPath: filename)
                }

                // write to file
                fileManager.createFile(atPath: filename,
                                       contents: imageData,
                                       attributes: nil)
                Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
            }
        }
    }
    
    internal func writeProcessedPreview(_ image: PixelatedImage) {
        // write out a preview of the processed file
        if config.writeFrameProcessedPreviewFiles {
            if let processedPreviewImage = image.baseImage(ofSize: self.previewSize,
                                                      fromData: image.imageData.data),
               let imageData = processedPreviewImage.jpegData,
               let filename = self.processedPreviewFilename
            {
                do {
                    if fileManager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing processed preview \(filename)")
                        try fileManager.removeItem(atPath: filename)
                    }

                    // write to file
                    fileManager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        }
    }

    public func writePreviewFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFramePreviewFiles,
           let filename = self.previewFilename
        {
            if fileManager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing preview \(filename)")
                return
            }
            
            Log.d("frame \(self.frameIndex) doing preview")

            if let scaledImage = image.resized(to: self.previewSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                fileManager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    public func writeThumbnailFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFrameThumbnailFiles,
           let filename = self.thumbnailFilename
        {
            if fileManager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing thumbnail filename \(filename)")
                return
            }

            Log.d("frame \(self.frameIndex) doing thumbnail")
            let thumbnailWidth = config.thumbnailWidth
            let thumbnailHeight = config.thumbnailHeight
            let thumbnailSize = NSSize(width: thumbnailWidth, height: thumbnailHeight)
            
            if let scaledImage = image.resized(to: thumbnailSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                fileManager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote thumbnail to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {

        Log.d("frame \(self.frameIndex) writeOutlierValuesCSV")
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            // write out the decision tree value matrix too
            //Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1")

            let frameOutlierDir = "\(outputDirname)/\(self.frameIndex)"
            let positiveFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
            let negativeFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.negativeDataFilename)"

            // check to see if both of these files exist already
            if fileManager.fileExists(atPath: positiveFilename),
               fileManager.fileExists(atPath: negativeFilename) {
                Log.i("frame \(self.frameIndex) not recalculating outlier values with existing files")
            } else {
                let valueMatrix = OutlierGroupValueMatrix()
                
                if let outliers = self.outlierGroupList() {
                    //Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1a \(outliers.count) outliers")
                    for outlier in outliers {
                        //Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1b")
                        await valueMatrix.append(outlierGroup: outlier)
                    }
                }
                //Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 2")

                try valueMatrix.writeCSV(to: frameOutlierDir)
                //Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 3")
            }
        }
        //Log.d("frame \(self.frameIndex) DONE writeOutlierValuesCSV")
    }

    // write out a directory of individual OutlierGroup binaries
    // for each outlier in this frame
    // large, still not fast, but lots of data
    public func writeOutliersBinary() async {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            do {
                try await self.outlierGroups?.write(to: outputDirname)
            } catch {
                Log.e("error \(error)")
            }                
        }
    }
    internal func save16BitMonoImageData(_ subtractionArray: [UInt16],
                                        to filename: String) throws -> PixelatedImage
    {
        let outlierAmountImage = PixelatedImage(width: width,
                                                height: height,
                                                grayscale16BitImageData: subtractionArray)
        // write out the subtractionArray here as an image
        try outlierAmountImage.writeTIFFEncoding(toFilename: filename)

        return outlierAmountImage
    }

}

fileprivate let fileManager = FileManager.default
