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

    // map of all known blobs keyed by blob id
    var blobMap: [UInt16: Blob]

    // width of the frame
    internal let width: Int

    // height of the frame
    internal let height: Int

    // what frame in the sequence we're processing
    internal let frameIndex: Int

    // a reference for each pixel for each blob it might belong to
    // non zero values reference a blob
    internal var blobRefs: [UInt16]

    // keep track of absorbed blobs so we don't reference them again accidentally
    internal var absorbedBlobs = Set<UInt16>()
    
    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int,
         frameIndex: Int)
    {

        self.blobMap =  blobMap
        self.width = width
        self.height = height
        self.frameIndex = frameIndex

        self.blobRefs = [UInt16](repeating: 0, count: width*height)

        for blob in blobMap.values {
            for pixel in blob.pixels {
                let blobRefIndex = pixel.y*width+pixel.x
                blobRefs[blobRefIndex] = blob.id
            }
        }
    }

    // skips blobs that are absorbed during iteration
    internal func iterateOverAllBlobs(closure: (Int, Blob) -> Void) {
        // iterate over largest blobs first
        let allBlobs = blobMap.values.sorted() { $0.size > $1.size }
        for (index, blob) in allBlobs.enumerated() {
            if !absorbedBlobs.contains(blob.id) {
                closure(index, blob)
            }
        }
    }
}
    
