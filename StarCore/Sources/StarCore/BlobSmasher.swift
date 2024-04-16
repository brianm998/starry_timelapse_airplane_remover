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

            Log.d("frame \(frameIndex) Smasher has a total of \(self.blobMap.count) blobs")
        }
    }

    private func smash(blob: Blob,
                       alreadyScannedBlobs: Set<String> = Set<String>(),
                       iterationCount: Int = 1,
                       previousBoundingBox: BoundingBox? = nil)
    {
        /*

         define a search area around the blob.

         look around it, seeing if there are any other blobs nearby.

         if so, try to line merge them into this blob
         if not, keep track of ones that didn't line merge well and don't do it again

         if we get a successfull line merge, then recurse and start again.

         // XXX THIS FILE HAS A BIG MEMORY LEAK WHICH CAUSES A KILL -9 from the OS :(
         
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

        Log.d("frame \(frameIndex) trying to smash blob \(blob) iteration \(iterationCount) ideal avd \(blob.averageDistanceFromIdealLine) from originZeroLine \(blob.originZeroLine) blob.line \(blob.line) tp \(blob.line?.twoPoints) searching [\(startX), \(startY)] to [\(endX), \(endY)]")

        var alreadyScannedBlobs = alreadyScannedBlobs

        var shouldRecurse = false

        var absorbingBlob = blob

        let currentBoundingBox = blob.boundingBox
        
        for x in (startX ... endX) {
            for y in (startY ... endY) {
                if let previousBoundingBox,
                   previousBoundingBox.contains(x: x, y: y) { continue }
                
                if let blobRef = blobRefs[y*width+x],
                   blobRef != absorbingBlob.id,
                   !alreadyScannedBlobs.contains(blobRef),
                   let otherBlob = blobMap[blobRef]
                {
                    Log.d("frame \(frameIndex) \(absorbingBlob) is nearby \(otherBlob)")
                    // we found another blob close by that we've not already looked at
                    alreadyScannedBlobs.insert(otherBlob.id)

                    if let mergedBlob = absorbingBlob.lineMergeV2(with: otherBlob) {
                        // successful line merge
                        Log.d("frame \(frameIndex) successfully line merged blob \(absorbingBlob) with \(otherBlob)")
                        if mergedBlob.boundingBox != absorbingBlob.boundingBox {
                            // we will recurse now because absorbtion has
                            // changed the size of the blob's bounding box
                            shouldRecurse = true
                        }

                        blobMap.removeValue(forKey: absorbingBlob.id)
                        
                        // keep track of the larger blob for possible further enlargement
                        absorbingBlob = mergedBlob

                        // make sure the new blob is tracked in the blobMap
                        blobMap[mergedBlob.id] = mergedBlob

                        // otherBlob is now longer 
                        blobMap.removeValue(forKey: otherBlob.id)

                        // keep the removed blob out of this round of iteration
                        absorbedBlobs.insert(otherBlob.id)

                        // mark the newly absorbed pixels with a new blob id
                        for pixel in otherBlob.pixels {
                            blobRefs[pixel.y*width+pixel.x] = mergedBlob.id
                        }
                    } else {
                        Log.d("frame \(frameIndex) could not line merged blob \(absorbingBlob) with \(otherBlob)")
                    }
                }
            }
        }
        if true,               // XXX REWRITE THIS SO IT DOESN'T TAKE FOREVER AND HOG TOO MUCH RAM
           /*
            one solution would be to keep a full frame map of visited pixels, boolean for each,
            and upon re-smash, ignore any pixels already seen

            or pass in the previous bounding box searched, and use that?

             ^^^^^^^

             do this next to speed things up, recursion here was killing it


             NEXT TRY:

             - identify BoundingBoxes for each absorbed blob
             - remove parts of them that have been already scanned
             - iterate over this list instead of recursing like this

             WHAT ABOUT:

             - keep one frame sized array of UInt16 values, one per pixel
             - for each blob iteration, choose a number, this number is the one for the array
             - call the inner smash function with a particular bounding box
               - ignore all pixels already marked with our number
               - mark all pixels with our number after processing
               - return a list of bounding boxes of absorbed blobs
               - add any returned bounding boxes to the list to process
               - unless they are fully within the bounding box of the original box
             
             
            */
           shouldRecurse
        {
            Log.d("frame \(frameIndex) recursing on blob \(absorbingBlob) after \(iterationCount) iterations")
            smash(blob: absorbingBlob,
                  alreadyScannedBlobs: alreadyScannedBlobs,
                  iterationCount: iterationCount + 1,
                  previousBoundingBox: currentBoundingBox)
        }
    }
}
