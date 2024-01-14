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

// combines any overlapping blobs
class BlobRectifier {

    // map of all known blobs keyed by blob id
    var blobMap: [String: Blob]

    // width of the frame
    internal let width: Int

    // height of the frame
    internal let height: Int

    // what frame in the sequence we're processing
    internal let frameIndex: Int

    // a reference for each pixel for each blob it might belong to
    internal var blobRefs: [String?]
    
    init(blobMap: [String: Blob],
         width: Int,
         height: Int,
         frameIndex: Int)
    {
        self.blobMap =  blobMap
        self.width = width
        self.height = height
        self.frameIndex = frameIndex

        self.blobRefs = [String?](repeating: nil, count: width*height)

        for (key, blob) in self.blobMap {

            var overlappingBlob: Blob? = nil
            
            for pixel in blob.pixels {
                let index = pixel.y*width+pixel.x
                if let blobId = blobRefs[index] {
                    if blobId != blob.id,
                       let existingBlob = self.blobMap[blobId]
                    {
                        overlappingBlob = existingBlob
                        break
                    }
                }
            }
            if let overlappingBlob = overlappingBlob,
               overlappingBlob.absorb(blob)
            {
                self.blobMap.removeValue(forKey: blob.id)
                for pixel in blob.pixels {
                    let index = pixel.y*width+pixel.x
                    blobRefs[index] = overlappingBlob.id
                }
            } else {
                for pixel in blob.pixels {
                    let index = pixel.y*width+pixel.x
                    blobRefs[index] = blob.id
                }
            }
        }
    }


}
