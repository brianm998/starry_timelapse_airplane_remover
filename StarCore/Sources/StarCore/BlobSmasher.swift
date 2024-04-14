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

// tries to smash larger blobs together with a line merge
class BlobSmasher: AbstractBlobAnalyzer {

    public func process() {
        iterateOverAllBlobs() { index, blob in 
            if blob.size < 20 { return } // XXX constant

            smash(blob: blob)
        }
    }

    private func smash(blob: Blob,
                       alreadyScannedBlobs: Set<String> = Set<String>())
    {
        /*

         define a search area around the blob.

         look around it, seeing if there are any other blobs nearby.

         if so, try to line merge them into this blob
         if not, keep track of ones that didn't line merge well and don't do it again

         if we get a successfull line merge, then recurse and start again.
         
         */

        // how far outside the blob's bounding box to search
        var searchBorderSize = 20 // XXX constant
        
        let blobCenter = blob.boundingBox.center
        
        var startX = blob.boundingBox.min.x - searchBorderSize
        var startY = blob.boundingBox.min.y - searchBorderSize
        
        if startX < 0 { startX = 0 }
        if startY < 0 { startY = 0 }

        var endX = blob.boundingBox.max.x + searchBorderSize
        var endY = blob.boundingBox.max.y + searchBorderSize

        if endX >= width { endX = width - 1 }
        if endY >= height { endY = height - 1 }

        Log.d("frame \(frameIndex) trying to smash blob \(blob) ideal avd \(blob.averageDistanceFromIdealLine) from originZeroLine \(blob.originZeroLine) blob.line \(blob.line) tp \(blob.line?.twoPoints) searching [\(startX), \(startY)] to [\(endX), \(endY)]")

        var alreadyScannedBlobs = alreadyScannedBlobs

        var shouldRecurse = false

        var absorbingBlob = blob
        
        for x in (startX ... endX) {
            for y in (startY ... endY) {
                if let blobRef = blobRefs[y*width+x],
                   blobRef != absorbingBlob.id,
                   !alreadyScannedBlobs.contains(blobRef),
                   let otherBlob = blobMap[blobRef]
                {
                    Log.d("frame \(frameIndex) \(absorbingBlob) is nearby \(otherBlob)")
                    // we found another blob close by that we've not already looked at
                    alreadyScannedBlobs.insert(otherBlob.id)

                    if let absorbedBlob = absorbingBlob.lineMergeV2(with: otherBlob) {
                        // successful line merge
                        Log.d("frame \(frameIndex) successfully line merged blob \(absorbingBlob) with \(otherBlob)")
                        // keep track of the larger blob for possible further enlargement
                        absorbingBlob = absorbedBlob
                        
                        // we will recurse now because absorbtion may have 
                        // changed the size of the blob.
                        shouldRecurse = true

                        // make sure the new blob is tracked in the blobMap
                        blobMap[absorbedBlob.id] = absorbedBlob

                        // otherBlob is now longer 
                        blobMap.removeValue(forKey: otherBlob.id)

                        // keep the removed blob out of this round of iteration
                        absorbedBlobs.insert(otherBlob.id)

                        // mark the newly absorbed pixels with a new blob id
                        for pixel in otherBlob.pixels {
                            blobRefs[pixel.y*width+pixel.x] = absorbedBlob.id
                        }
                    } else {
                        Log.d("frame \(frameIndex) could not line merged blob \(absorbingBlob) with \(otherBlob)")
                    }
                }
            }
        }
        if shouldRecurse {
            Log.d("frame \(frameIndex) recursing on blob \(absorbingBlob)")
            smash(blob: absorbingBlob,
                  alreadyScannedBlobs: alreadyScannedBlobs)
        }
    }
}
