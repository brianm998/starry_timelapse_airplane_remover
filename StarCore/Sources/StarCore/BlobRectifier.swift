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
class BlobRectifier: AbstractBlobAnalyzer {

    public func process() {
        iterateOverAllBlobs() { _, blob in 

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
            if let overlappingBlob,
               overlappingBlob.absorb(blob)
            {
                absorbedBlobs.insert(blob.id)
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
