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

    // keep track of absorbed blobs so we don't reference them again accidentally
    internal var absorbedBlobs = Set<String>()
    
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
        
    // looks around for blobs close to this place
    internal func processBlobsAt(x sourceX: Int,
                                 y sourceY: Int,
                                 on line: Line,
                                 iterationOrientation: IterationOrientation,
                                 lastBlob: inout LastBlob) 
    {

        //Log.d("frame \(frameIndex) processBlobsAt [\(sourceX), \(sourceY)] on line \(line) lastBlob \(lastBlob)")
                            
        // XXX calculate this differently based upon the theta of the line
        // a 45 degree line needs more extension to have the same distance covered
        var searchDistanceEachDirection = 16 // XXX constant

        var startX = sourceX
        var startY = sourceY

        var endX = sourceX+1
        var endY = sourceY+1
        
        switch iterationOrientation {
        case .vertical:
            startY -= searchDistanceEachDirection
            endY += searchDistanceEachDirection
            if startY < 0 { startY = 0 }
            
            //Log.d("frame \(frameIndex) processing vertically from \(startY) to \(endY) on line \(line) lastBlob \(lastBlob.blob)")
            if startY < endY {
                for y in startY ..< endY {
                    processBlobAt(x: sourceX, y: y,
                                  on: line,
                                  lastBlob: &lastBlob)
                }
            }
            
        case .horizontal:
            startX -= searchDistanceEachDirection
            endX += searchDistanceEachDirection
            if startX < 0 { startX = 0 }
            
            //Log.d("frame \(frameIndex) processing horizontally from \(startX) to \(endX) on line \(line) lastBlob \(lastBlob.blob)")
            
            if startY < endY {
                for x in startX ..< endX {
                    processBlobAt(x: x, y: sourceY,
                                  on: line,
                                  lastBlob: &lastBlob)
                }
            }
        }
    }

    // process a blob at this particular spot
    internal func processBlobAt(x: Int, y: Int,
                                on line: Line,
                                lastBlob: inout LastBlob) 
    {
        if y < height,
           x < width,
           let blobId = blobRefs[y*width+x],
           let blob = blobMap[blobId]
        {
            // lines are invalid for this blob
            // if there is already a line on the blob and it doesn't match
            var lineIsValid = true

            var lineForNewBlobs = line
            if let blobLine = blob.line {
                lineForNewBlobs = blobLine
                lineIsValid = blobLine.thetaMatch(line, maxThetaDiff: 16) // medium, 20 was generous, and worked

//                if !lineIsValid {
                    //Log.i("frame \(frameIndex) HOLY CRAP [\(x), \(y)]  blobLine \(blobLine) from \(blob) doesn't match line \(line)")
//                }
            }

            if lineIsValid { 
                if let _lastBlob = lastBlob.blob {
                    if _lastBlob.id != blob.id  {
                        let distance = _lastBlob.boundingBox.edgeDistance(to: blob.boundingBox)
                        //Log.i("frame \(frameIndex) blob \(_lastBlob) bounding box \(_lastBlob.boundingBox) is \(distance) from blob \(blob) bounding box \(blob.boundingBox)")
                        if distance < 40 { // XXX constant XXX
                            // if they are close enough, simply combine them

                            var proceed = true

                            // check the center of blob for how far it is from the

                            if let idealLastLine = _lastBlob.line,
                               blob.averageDistance(from: idealLastLine) > 6 // XXX constant XXX
                            {
                                // here we have a blob with a similar line,
                                // but is too far from the line it should be on (rho diff)
                                proceed = false
                            }
                            
                            if proceed,
                               _lastBlob.absorb(blob)
                            {
                                absorbedBlobs.insert(blob.id)
                                Log.d("frame \(frameIndex)  blob \(_lastBlob) absorbing blob \(blob)")

                                // update blobRefs after blob absorbtion
                                for pixel in blob.pixels {
                                    let blobRefIndex = pixel.y*width+pixel.x
                                    blobRefs[blobRefIndex] = _lastBlob.id
                                }

                                blobMap.removeValue(forKey: blob.id)

                            } else {
                                if _lastBlob.id != blob.id {
                                    //Log.i("frame \(frameIndex) [\(x), \(y)] blob \(_lastBlob) failed to absorb blob \(blob)")
                                }
                            }
                        } else {
                            // if they are far, then overwrite the lastBlob var
                            //Log.d("frame \(frameIndex) [\(x), \(y)] distance \(distance) from \(_lastBlob) is too far from blob with id \(blob) line \(lineForNewBlobs)")
                            lastBlob.blob = blob
                        }
                    }
                } else {
                    //Log.d("frame \(frameIndex) [\(x), \(y)] no last blob, blob \(blob) is now last - line \(lineForNewBlobs)")
                    lastBlob.blob = blob
                }
            }
        }
    }
}
    
