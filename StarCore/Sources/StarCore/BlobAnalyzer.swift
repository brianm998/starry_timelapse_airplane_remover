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


public class LastBlob {
    var blob: Blob?
}

// skeleton for analyzer of blobs that can then manipulate the blobs in some way
final public class BlobAnalyzer: @unchecked Sendable {

    // map of all known blobs keyed by blob id
    private var blobMap: [UInt16: Blob]

    // width of the frame
    internal let width: Int

    // height of the frame
    internal let height: Int

    // what frame are we on?
    internal let frameIndex: Int

    // a reference for each pixel for each blob it might belong to
    // non zero values reference a blob
    internal var blobRefs: [UInt16]

    internal var maxBlobId: UInt16 = 0

    var pixelatedImage: PixelatedImage {
        .init(width: self.width,
              height: self.height,
              grayscale16BitImageData: blobRefs)
    }
    
    func blobs(with blobIdSet: Set<UInt16>) -> [Blob] {
        blobIdSet.compactMap { blobMap[$0] }
    }

    func blob(at x: Int, and y: Int) -> Blob? {
        let index = y*width+x
        if index >= 0,
           index < blobRefs.count
        {
            let blobId = blobRefs[index]
            if blobId != 0 { return blobMap[blobId] }
        }
        return nil
    }
    
    func blob(with blobId: UInt16) -> Blob? { blobMap[blobId] }
    
    func update(blob: Blob) async {
        blobMap[blob.id] = blob

        // update blob refs, check for errors
        for pixel in await blob.getPixels() {
            let index = pixel.y*width+pixel.x
            let existingBlobId = blobRefs[index]
            if existingBlobId != 0,
               existingBlobId != blob.id
            {
                if let existingBlob = blobMap[existingBlobId] {
                    await existingBlob.remove(pixel: pixel)
                }
            }
            blobRefs[index] = blob.id
        }
    }
    
    func remove(blob: Blob) async {
        blobMap.removeValue(forKey: blob.id)

        // update blob refs
        for pixel in await blob.getPixels() {
            let index = pixel.y*width+pixel.x
            if blobRefs[index] == blob.id {
                blobRefs[index] = 0
            }
        }
    }

    func replace(blob: Blob, with other: Blob) async {
        blobMap[other.id] = other
        blobMap.removeValue(forKey: blob.id)

        // update blob refs
        for pixel in await blob.getPixels() {
            let index = pixel.y*width+pixel.x
            if blobRefs[index] == blob.id {
                blobRefs[index] = other.id
            }
        }
    }

    func mapOfBlobs() -> [UInt16: Blob] { blobMap }
    
    func blobs() -> [Blob] {
        Array(blobMap.values)
    }
    
    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int,
         frameIndex: Int,
         step: String = "??",
         logDupeBlobs: Bool = false) async
    {
        self.blobMap = blobMap
        self.width = width
        self.height = height
        self.frameIndex = frameIndex

        let startTime = Date().timeIntervalSince1970
        
        var _blobRefs = [UInt16](repeating: 0, count: width*height)
        
        Log.d("frame \(frameIndex) has \(blobMap.count) blobs")
        
        for blob in blobMap.values {
            if blob.id > maxBlobId { maxBlobId = blob.id }
            for pixel in await blob.getPixels() {
//                Log.d("frame \(frameIndex) has pixel [\(pixel.x), \(pixel.y)]")
                let blobRefIndex = pixel.y*width+pixel.x

                if logDupeBlobs,
                   _blobRefs[blobRefIndex] != 0
                {
                    let errorString =
                      "frame \(frameIndex) step \(step) has duplicate blob at \(pixel)"
                    Log.w(errorString)
                    fatalError(errorString)
                }
                
                _blobRefs[blobRefIndex] = blob.id
            }
        }
        self.blobRefs = _blobRefs
        let endTime = Date().timeIntervalSince1970

        Log.d("blob analyzer init took \(endTime-startTime) seconds")
    }

    // skips blobs that are absorbed during iteration
    internal func iterateOverAllBlobs(closure: @Sendable (UInt16, Blob) async -> Void) async {
        // iterate over largest blobs first

        // prepare synchronous sorting with separate map 
        var blobSizes: [BlobSize] = []
        for (id, blob) in blobMap {
            blobSizes.append(BlobSize(id: id, size: await blob.size(), blob: blob))
        }

        let sortedIds = blobSizes.sorted { $0.size > $1.size }
        
        for id in sortedIds {
            await closure(id.id, id.blob)
        }
    }

    // returns a set of blobs that are directly within scanSize of blob's bounding box
    // certain neighbors can be excluded with the blobMattersClosure returning false
    // if requiredNeighbors is set, no more than that number of neighbors will be returned.
    internal func directNeighbors(of blob: Blob,
                                  scanSize: Int = 12,
                                  requiredNeighbors: Int? = nil,
                                  blobMattersClosure:  (@Sendable (Blob) async -> Bool)? = nil) async -> Set<Blob>
    {
        let boundingBox = await blob.boundingBox()
        
        var startX = boundingBox.min.x - scanSize
        var startY = boundingBox.min.y - scanSize
        
        if startX < 0 { startX = 0 }
        if startY < 0 { startY = 0 }

        var endX = boundingBox.max.x + scanSize
        var endY = boundingBox.max.y + scanSize

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
                    if await blobMattersClosure?(otherBlob) ?? true {
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
                                processedBlobs: ProcessedBlobs) async -> (Set<Blob>, ProcessedBlobs)
    {
        var blobsToProcess = [blob]
        var ret: Set<Blob> = []

        while blobsToProcess.count > 0 {
            let blobToProcess = blobsToProcess.removeFirst()
            for otherBlob in await self.directNeighbors(of: blobToProcess, scanSize: scanSize) {
                if !(await processedBlobs.contains(otherBlob.id)) {
                    await processedBlobs.insert(otherBlob.id)
                    ret.insert(otherBlob)
                    blobsToProcess.append(otherBlob)
                }
            }
        }
        return (ret, processedBlobs)
    }

    public func logBlobs() async {
        Log.d("frame \(frameIndex) has \(blobMap.count) blobs")
        for (_, blob) in blobMap {
            Log.d("frame \(frameIndex) blob.id \(blob.id) \(await blob.size()) pixels \(await blob.pixels)")
        }
    }
}
    
fileprivate struct BlobSize {
    let id: UInt16
    let size: Int
    let blob: Blob
}
