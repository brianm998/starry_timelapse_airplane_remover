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

 Image subtraction logic
 
 */
extension FrameAirplaneRemover {
    // returns a grayscale image pixel value array from subtracting the aligned frame
    // from the frame being processed.
    internal func subtractAlignedImageFromFrame() async throws -> [UInt16] {
        self.state = .loadingImages
        
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // use star aligned image
        let otherFrame = try await imageSequence.getImage(withName: starAlignedSequenceFilename).image()

        self.state = .subtractingNeighbor
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        Log.i("frame \(frameIndex) finding outliers")

        // the grayscale image pixel array to return when we've calculated it
        var subtractionArray = [UInt16](repeating: 0, count: width*height)

        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let origData = image.rawImageData

        let otherData = otherFrame.rawImageData

        // most of the time is in this loop, although it's a lot faster now
        // ugly, but a lot faster
        origData.withUnsafeBytes { unsafeRawPointer in 
            let origImagePixels: UnsafeBufferPointer<UInt16> =
                unsafeRawPointer.bindMemory(to: UInt16.self)

            otherData.withUnsafeBytes { unsafeRawPointer1  in 
                let otherImagePixels: UnsafeBufferPointer<UInt16> =
                  unsafeRawPointer1.bindMemory(to: UInt16.self)

                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let origOffset = (y * width*image.pixelOffset) +
                                         (x * image.pixelOffset)
                        let otherOffset = (y * width*otherFrame.pixelOffset) +
                                          (x * otherFrame.pixelOffset)
                        
                        var maxBrightness: Int32 = 0
                        
                        if otherFrame.pixelOffset == 4,
                           otherImagePixels[otherOffset+3] != 0xFFFF
                        {
                            // ignore any partially or fully transparent pixels
                            // these crop up in the star alignment images
                            // there is nothing to copy from these pixels
                        } else {
                            // rgb values of the image we're modifying at this x,y
                            let origRed = Int32(origImagePixels[origOffset])
                            let origGreen = Int32(origImagePixels[origOffset+1])
                            let origBlue = Int32(origImagePixels[origOffset+2])
                            
                            // rgb values of an adjecent image at this x,y
                            let otherRed = Int32(otherImagePixels[otherOffset])
                            let otherGreen = Int32(otherImagePixels[otherOffset+1])
                            let otherBlue = Int32(otherImagePixels[otherOffset+2])

                            maxBrightness += origRed + origGreen + origBlue
                            maxBrightness -= otherRed + otherGreen + otherBlue
                        }
                        // record the brightness change if it is brighter
                        if maxBrightness > 0 {
                            subtractionArray[y*width+x] = UInt16(maxBrightness/3)
                        }
                    }
                }
            }
        }

        if config.writeOutlierGroupFiles {
            // write out image of outlier amounts
            do {
                let subtractionImage = try save16BitMonoImageData(subtractionArray,
                                                                  to: alignedSubtractedFilename)
                Log.d("frame \(frameIndex) saved subtraction image")
                try writeSubtractionPreview(subtractionImage)
                Log.d("frame \(frameIndex) saved subtraction image preview")
            } catch {
                Log.e("can't write subtraction image: \(error)")
            }
        }
        
        return subtractionArray
    }
}
