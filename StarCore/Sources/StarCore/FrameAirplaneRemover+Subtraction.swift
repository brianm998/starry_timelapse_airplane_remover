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
        
//        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()
        if let image = try await imageAccessor.load(type: .original, atSize: .original),
           let otherFrame = try await imageAccessor.load(type: .aligned, atSize: .original)
        {
            self.state = .subtractingNeighbor
            
            Log.i("frame \(frameIndex) finding outliers")

            let subtractionImage = image.subtract(otherFrame)
            
            if config.writeOutlierGroupFiles {
                // write out image of outlier amounts
                do {
                    try await imageAccessor.save(subtractionImage, as: .subtracted,
                                              atSize: .original, overwrite: false)
                    try await imageAccessor.save(subtractionImage, as: .subtracted,
                                              atSize: .preview, overwrite: false)
                } catch {
                    Log.e("can't write subtraction image: \(error)")
                }
            }

            switch subtractionImage.imageData {
            case .eightBit(_):
                fatalError("eight bit images not supported here now")
            case .sixteenBit(let data):
                return data 
            }
        } else {
            throw "couldn't load images"
        }
    }
}