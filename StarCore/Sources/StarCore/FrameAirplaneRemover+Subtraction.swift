import Foundation
import CoreGraphics
import logging
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
    internal func subtractAlignedImageFromFrame() async throws -> PixelatedImage {
        // first try to load the subtracted image directly from file

        let accessor = imageAccessor
        
        if let image = await imageAccessor.load(type: .subtracted, atSize: .original) {
            return image
        }

        // if we don't have the subtracted image on file yet, make it
        Log.d("frame \(frameIndex) subtractAlignedImageFromFrame")


        // load the original
        guard let image = await accessor.load(type: .original, atSize: .original)
        else {
            Log.e("frame \(frameIndex) couldn't load original image")
            // XXX these should really throw an error, and that really should
            // be handled properly at a higher level, but right now, thrown errors
            // from here end up in the bitbucket :(  Need to figure out why
            throw "frame \(frameIndex) couldn't original image"
        }
        Log.d("frame \(frameIndex) got orig image")
        
        // load or create the aligned frame
        var alignedFrame = await accessor.load(type: .aligned, atSize: .original)
        if alignedFrame == nil {
            // try creating the star aligned image if we can't load it
            alignedFrame = await starAlignedImage()
        }

        guard let alignedFrame else {
            let error = "frame \(frameIndex) can't load the star aligned image"
            Log.e(error)
            throw error
        }
        
        Log.d("frame \(frameIndex) got aligned image")
        
        self.set(state: .subtractingNeighbor)
        
        Log.i("frame \(frameIndex) finding outliers")

        // subtract them
        // result is image - alignedFrame
        // any pixel which is bright in image but not bright in alignedFrame
        // will be bright in the subtractionImage
        let subtractionImage = image.subtract(alignedFrame)
        
        if config.writeOutlierGroupFiles {
            // write out image of outlier amounts
            do {
                try await accessor.save(subtractionImage, as: .subtracted,
                                             atSize: .original, overwrite: false)
                try await accessor.save(subtractionImage, as: .subtracted,
                                             atSize: .preview, overwrite: false)
            } catch {
                Log.e("frame \(frameIndex) can't write subtraction image: \(error)")
            }
        }

        return subtractionImage
    }
}
