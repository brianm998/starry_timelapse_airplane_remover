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

// tries to smash blobs together, but only if they look more like a line after doing so
class BlobSmasher: AbstractBlobAnalyzer {

    public func process() {
        iterateOverAllBlobs() { index, blob in 
            if blob.size < minimumBlobSize { return }

            self.alreadyScannedBlobs = Set<String>()
            
            smash(blob: blob)

            Log.d("frame \(frameIndex) Smasher has a total of \(self.blobMap.count) blobs")
        }
    }

    private var absorbingBlob: Blob = Blob(frameIndex: 0) // XXX dummy

    private var alreadyScannedBlobs = Set<String>()

    // full frame array of what pixels are used by what blob
    // values in it come from currentIndex
    private lazy var usedPixels = [UInt16](repeating: 0, count: self.width*self.height)

    // the current index that we use to mark usage of blobs in usedPixels above.
    // we simply increment it upon a new blob to avoid having to reset the entire array each time
    private var currentIndex: UInt16 = 0 

    // when a blob gets bigger than this, stop smashing it
    // things like clouds or foreground features can make really large blobs,
    // which slows us down a lot.
    private let maximumBlobSize = 1000 // XXX constant

    // how far outside the blob's bounding box to search
    private let searchBorderSize = 20 // XXX constant

    // blobs smaller than this cannot initiate the smash
    // they can however be later absorbed by larger blobs if nearby
    private let minimumBlobSize = 20 // XXX constant
    
    // attempt to make this blob bigger by absorbing nearby blobs 
    private func smash(blob: Blob) {
        /*

         define a search area around the blob.

         look around it, seeing if there are any other blobs nearby.

         if so, try to line merge them into this blob
         if not, keep track of ones that didn't line merge well and don't do it again

         if we get a successfull line merge, then recurse and start again.

         // XXX THIS FILE HAS A BIG MEMORY LEAK WHICH CAUSES A KILL -9 from the OS :(
         

             - keep one frame sized array of UInt16 values, one per pixel
             - for each blob iteration, choose a number, this number is the one for the array
             - call the inner smash function with a particular bounding box
               - ignore all pixels already marked with our number
               - mark all pixels with our number after processing
               - return a list of bounding boxes of absorbed blobs
               - add any returned bounding boxes to the list to process
               - unless they are fully within the bounding box of the original box

            XXX really large blobs end up in foreground sometimes, and slow this down a LOT
               - trying a maximum Blob Size, seems to really help
            
            XXX sometimes blobs get smashed with blobs that don't match at all
            
            XXX sometimes a few small blobs are missing from an obvious line blob, middle or ends
               
         */


        Log.d("frame \(frameIndex) trying to smash blob \(blob)")

        currentIndex += 1       // look for this volue in usedPixels

        var boundingBoxes: [BoundingBox] = []
        boundingBoxes.append(blob.boundingBox) // start with the blob's bounding box

        absorbingBlob = blob
        
        while(boundingBoxes.count > 0 && absorbingBlob.size < maximumBlobSize) {
            Log.d("iterating on \(boundingBoxes.count) boundingBoxes")
            let next = boundingBoxes.removeFirst()
            // inner smash may contain extra bounding boxes to search in 
            boundingBoxes.append(contentsOf: self.innerSmash(boundingBox: next))
        }
        
    }

    /*
     The actual smash logic.

     given a bounding box, attempt to see what other blobs are in it,
     and if they are a good match for being absorbed into self.absorbingBlob
     */
    private func innerSmash(boundingBox: BoundingBox) -> [BoundingBox] {
        
        var startX = boundingBox.min.x - searchBorderSize
        var startY = boundingBox.min.y - searchBorderSize
        
        if startX < 0 { startX = 0 }
        if startY < 0 { startY = 0 }

        var endX = boundingBox.max.x + searchBorderSize
        var endY = boundingBox.max.y + searchBorderSize

        if endX >= width { endX = width - 1 }
        if endY >= height { endY = height - 1 }

        var ret: [BoundingBox] = []
        
        for x in (startX ... endX) {
            for y in (startY ... endY) {
                let frameIndex = y*width+x
                let pixelUsage = usedPixels[frameIndex]  // get any previous usage of this pixel
                if pixelUsage != currentIndex,           // make sure we haven't already seen this
                   let blobRef = blobRefs[frameIndex],   // is there a blob at this pixel?
                   blobRef != absorbingBlob.id,          // disregard the current blob
                   !alreadyScannedBlobs.contains(blobRef), // don't re-process blobs
                   let otherBlob = blobMap[blobRef]        // get the actual other blob to look at
                {
                    Log.d("frame \(frameIndex) \(absorbingBlob) is nearby \(otherBlob)")
                    // we found another blob close by that we've not already looked at

                    // make sure we don't process this blob more than once
                    alreadyScannedBlobs.insert(otherBlob.id)

                    // make sure this pixel isn't used again
                    usedPixels[frameIndex] = currentIndex
                    
                    if let mergedBlob = absorbingBlob.lineMergeV2(with: otherBlob) {
                        // successful line merge
                        Log.d("frame \(frameIndex) successfully line merged blob \(absorbingBlob) with \(otherBlob)")

                        if !absorbingBlob.boundingBox.contains(otherBlob.boundingBox) {
                            // XXX apply the searchBorderSize to this XXX
                            // XXX some bounding boxes are making it through when they don't need to
                            // could be faster if we remove already searched pixels from
                            // this new bounding box
                            ret.append(otherBlob.boundingBox)
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
                        //Log.d("frame \(frameIndex) could not line merged blob \(absorbingBlob) with \(otherBlob)")
                    }
                }
            }
        }
        return ret
    }
}
