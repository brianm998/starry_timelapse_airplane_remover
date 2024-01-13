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


class LastBlob {
    var blob: Blob?
}

// skeleton for analyzer of blobs that can then manipulate the blobs in some way
class AbstractBlobAnalyzer {

    // the output from the analyzer
    var filteredBlobs: [Blob] = []

    // map of all known blobs keyed by blob id
    var blobMap: [String: Blob]

    internal let config: Config

    // width of the frame
    internal let width: Int

    // height of the frame
    internal let height: Int

    // what frame in the sequence we're processing
    internal let frameIndex: Int

    // gives access to images
    internal let imageAccessor: ImageAccess

    // a reference for each pixel for each blob it might belong to
    internal var blobRefs: [String?]

    init(blobMap: [String: Blob],
         config: Config,
         width: Int,
         height: Int,
         frameIndex: Int,
         imageAccessor: ImageAccess) 
    {

        self.blobMap =  blobMap
        self.config = config
        self.width = width
        self.height = height
        self.frameIndex = frameIndex
        self.imageAccessor = imageAccessor

        self.blobRefs = [String?](repeating: nil, count: width*height)

        for (key, blob) in blobMap {
            for pixel in blob.pixels {
                blobRefs[pixel.y*width+pixel.x] = blob.id
            }
        }
    }
}
    
