import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// saves the given set of blobs as a 16 bit grayscale image,
// pixel values come from blob id number
class BlobImageSaver: AbstractBlobAnalyzer {

    public func save(to filename: String) {
        // save the blob refs as an image here
        do {
            Log.d("frame \(frameIndex) saving image to \(filename)")
            let blobImage = PixelatedImage(width: width, height: height,
                                           grayscale16BitImageData: blobRefs)
            try blobImage.writeTIFFEncoding(toFilename: filename)
            Log.d("frame \(frameIndex) done saving image to \(filename)")
        } catch {
            Log.e("frame \(frameIndex) error saving image \(filename): \(error)")
        }
        Log.d("frame \(frameIndex) REALLY done saving image to \(filename)")
    }
}
