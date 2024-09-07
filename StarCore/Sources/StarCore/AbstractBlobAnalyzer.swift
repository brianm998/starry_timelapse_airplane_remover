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
    
    // a reference for each pixel for each blob it might belong to
    // non zero values reference a blob
    internal var blobRefs: [UInt16]

    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int)
    {

        self.blobMap =  blobMap
        self.width = width
        self.height = height

        self.blobRefs = [UInt16](repeating: 0, count: width*height)

        for blob in blobMap.values {
            for pixel in blob.pixels {
                let blobRefIndex = pixel.y*width+pixel.x
                blobRefs[blobRefIndex] = blob.id
            }
        }
    }

    // skips blobs that are absorbed during iteration
    internal func iterateOverAllBlobs(closure: (UInt16, Blob) -> Void) {
        // iterate over largest blobs first
        let allBlobs = blobMap.values.sorted() { $0.size > $1.size }
        for (index, blob) in allBlobs.enumerated() {
            closure(blob.id, blob)
        }
    }

    // returns a set of blobs that are directly within scanSize of blob's bounding box
    // certain neighbors can be excluded with the blobMattersClosure returning false
    // if requiredNeighbors is set, no more than that number of neighbors will be returned.
    internal func directNeighbors(of blob: Blob,
                                  scanSize: Int = 12,
                                  requiredNeighbors: Int? = nil,
                                  blobMattersClosure: ((Blob) -> Bool)? = nil) -> Set<Blob>
    {
        var startX = blob.boundingBox.min.x - scanSize
        var startY = blob.boundingBox.min.y - scanSize
        
        if startX < 0 { startX = 0 }
        if startY < 0 { startY = 0 }

        var endX = blob.boundingBox.max.x + scanSize
        var endY = blob.boundingBox.max.y + scanSize

        if endX >= width { endX = width - 1 }
        if endY >= height { endY = height - 1 }
        
        var otherBlobsNearby: Set<Blob> = []

        for x in (startX ... endX) {
            for y in (startY ... endY) {
                let blobRef = blobRefs[y*width+x]
                if blobRef != 0,
                   blobRef != blob.id,
                   let otherBlob = blobMap[blobRef]
                {
                    if blobMattersClosure?(otherBlob) ?? true {
                        otherBlobsNearby.insert(otherBlob)
                        if let requiredNeighbors,
                           otherBlobsNearby.count >= requiredNeighbors { break }
                    }
                }
            }
            if let requiredNeighbors,
               otherBlobsNearby.count >= requiredNeighbors { break }
        }
        return otherBlobsNearby
    }

    // returns a set of neighbors, and a set of blob ids that have been processed already.
    // repeats the direct neighbor scan for all found neighbors,
    // so that all members of this neighbor set are within scanSize
    // pixels of some other member of the set.
    internal func neighborCloud(of blob: Blob,
                                scanSize: Int = 12,
                                processedBlobs: Set<UInt16> = []) -> (Set<Blob>, Set<UInt16>)
    {
        var blobsToProcess = [blob]
        var ret: Set<Blob> = []
        var processedBlobs = processedBlobs

        while blobsToProcess.count > 0 {
            let blobToProcess = blobsToProcess.removeFirst()
            for otherBlob in self.directNeighbors(of: blobToProcess, scanSize: scanSize) {
                if !processedBlobs.contains(otherBlob.id) {
                    processedBlobs.insert(otherBlob.id)
                    ret.insert(otherBlob)
                    blobsToProcess.append(otherBlob)
                }
            }
        }
        return (ret, processedBlobs)
    }
}
    
