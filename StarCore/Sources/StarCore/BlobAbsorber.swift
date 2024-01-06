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

public class BlobAbsorber {

    // a reference for each pixel for each blob it might belong to
    private var blobRefs: [String?]

    private var blobsProcessed: [String: Bool] = [:] // keyed by blob id, true if processed

    private let mask: CircularMask
    private let circularIterator: CircularIterator
    
    private var blobMap: [String: Blob]
    private var blobs: [Blob]
    
    // row major indexed array used for keeping track of checked pixels
    private var pixelProcessing: [String?]

    private var blobToAdd: Blob?
    
    var filteredBlobs: [Blob] = []
    
    let frameIndex: Int
    let frameWidth: Int
    let frameHeight: Int

    
    init(blobMap: [String: Blob],
         frameIndex: Int,
         frameWidth: Int,
         frameHeight: Int)
    {
        self.frameIndex = frameIndex
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.blobMap = blobMap
        self.blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")

        // sort by size, biggest first
        blobs.sort { $0.size > $1.size }
        
        self.blobRefs = [String?](repeating: nil, count: frameWidth*frameHeight)

        for blob in blobs {
            for pixel in blob.pixels {
                blobRefs[pixel.y*frameWidth+pixel.x] = blob.id
            }
        }

        let maskRadius: Int = 8 // XXX constant XXX
        // used for blobs with lines, convolved across line
        self.mask = CircularMask(radius: maskRadius)

        // used for blobs without lines, starts at center of blob
        self.circularIterator = CircularIterator(radius: 80) // XXX constant XXX
        
        // row major indexed array used for keeping track of checked pixels
        self.pixelProcessing = [String?](repeating: nil, count: frameWidth*frameHeight)

        for blob in blobs {
            Log.d("frame \(frameIndex) index \(index) filtering blob \(blob)")
            if let blobProcessed = blobsProcessed[blob.id],
               blobProcessed
            {
                continue
            }
            self.blobToAdd = blob
            blobsProcessed[blob.id] = true

            Log.d("frame \(frameIndex) index \(index) filtering blob \(blob)")

            if let blobLine = blob.line,
               let centralLineCoord = blob.centralLineCoord
            {
                // search along the line, convolving a small search area across it
                // search first one direction from the blob center,
                // then search the other direction from the blob center, to attach
                // closer blob first

                // iterate from central cooord on it
                // in both positive and negative directions
                // stop when we go too far or out of frame,
                // or too far from last blob point on the line

                /*

                 for iteration here, create a circular mask like the paint mask 

                 */
                
                blobLine.iterate(.forwards, from: centralLineCoord) { x, y, _ in
                    self.blobLineIterate(x, y)
                }

                blobLine.iterate(.backwards, from: centralLineCoord) { x, y, _ in
                    self.blobLineIterate(x, y)
                }
                
            } else {
                // search radially, in an ever expanding circle from the center point,
                // processing closer blobs first


                // create pixel mask like CenterMask, but allow sorting of pixels by distance
                // from center.
         
                var didAbsorb = false
                
                let blobCenter = blob.boundingBox.center

                // iterate out from the center
                circularIterator.iterate(x: blobCenter.x, y: blobCenter.y) { x, y in
                    if x >= 0,
                       y >= 0,
                       x < frameWidth,
                       y < frameHeight
                    {
                        let frameIndex = y*frameWidth+x

                        // see if there is another blob at this frame index that
                        // we can use to form a line
                        if process(frameIndex: frameIndex) {
                            // this blob and another were just combined and have a line
                            // need to switch to the line iteration
                            // and break out of this iteration loop.
                            didAbsorb = true
                            return false
                        }
                    }
                    return true
                }
                if didAbsorb,
                   let blobToAdd = blobToAdd,
                   let blobLine = blobToAdd.line,
                   let centralLineCoord = blobToAdd.centralLineCoord
                {
                    // here we found a blob that had no line and combined it with another
                    // and now there is a line.
                    // iterate across that line

                    blobLine.iterate(.forwards, from: centralLineCoord) { x, y, _ in
                        self.blobLineIterate(x, y)
                    }

                    blobLine.iterate(.backwards, from: centralLineCoord) { x, y, _ in
                        self.blobLineIterate(x, y)
                    }
                }
            }

            if let blobToAdd = blobToAdd {
                Log.d("frame \(frameIndex) adding filtered blob \(blobToAdd)")
                filteredBlobs.append(blobToAdd)
                self.blobToAdd = nil
            }
        }
    }

    // iterate across the circular mask centered at x/y
    private func blobLineIterate(_ x: Int, _ y: Int) -> Bool {

        let xStart = x - mask.radius
        let yStart = y - mask.radius

        let xEnd = x + mask.radius + 1
        let yEnd = y + mask.radius + 1

        // all of these cases are completely outside the frame
        if xStart > frameWidth { return false }
        if yStart > frameHeight { return false }
        if xEnd < 0 { return false }
        if yEnd < 0 { return false }

        
        mask.iterate { blobX, blobY in
            guard let blobToAdd = blobToAdd else { return }
            
            let frameX = xStart + blobX
            let frameY = yStart + blobY
            
            if frameX >= 0,
               frameY >= 0,
               frameX < frameWidth,
               frameY < frameHeight
            {
                process(frameIndex: frameY*frameWidth+frameX)
                // XXX also check here to see if this x/y is close to
                // blobToAdd, and use that to see how far away from
                // that blob we have become.
            }
        }

        /*
         XXX
         XXX
         XXX

         need more logic here to figure out how far we should iterate from the center


         proposal:

         - keep track of how far we are from the last pixel of the blob that we're tracking
         - don't go more than XXX pixels away from it


         
         XXX
         XXX
         XXX
        */
        
        return false            // XXX decide when to go further still 
    }


    // see if we can absorb another blob from the given frame index that makes
    // the blobToAdd a better line
    private func process(frameIndex: Int) -> Bool {
        guard let blobToAdd = blobToAdd else { return false }
        
        if let processingBlob = pixelProcessing[frameIndex],
           processingBlob == blobToAdd.id
        {
            // this blob has already processed this pixel
            return false
        }
        pixelProcessing[frameIndex] = blobToAdd.id

        // is there a different blob at this x,y?
        if let blobId = blobRefs[frameIndex],
           blobId != blobToAdd.id
        {
            if let blobProcessed = blobsProcessed[blobId],
               blobProcessed
            {
                // we've already processed this blob
                return false
            }
            if let innerBlob = blobMap[blobId],
               let absorbedBlob = blobToAdd.lineMerge(with: innerBlob)
            {
                // use this new blob as it is better combined than separate
                self.blobToAdd = absorbedBlob
                // ignore the index of the absorbed blob in the future
                blobsProcessed[innerBlob.id] = true

                for pixel in innerBlob.pixels {
                    blobRefs[pixel.y*frameWidth+pixel.x] = absorbedBlob.id
                }

                return true
            }
        }
        return false
    }
}


