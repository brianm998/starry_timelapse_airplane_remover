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

// gets rid of small blobs by themselves in nowhere
class IsolatedBlobRemover: AbstractBlobAnalyzer {

    public func process(minNeighborSize: Double = 0, // how big does a neighbor need to be to count?
                        scanSize: Int = 12) // how far in each direction to look for neighbors
    {
        iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if blob.adjustedSize > fx3Size(for: 24) { // XXX constant XXX
                return
            }

            var scanSize = scanSize
            
            // XXX constant XXX
               // each direction from center
/*
            if blob.medianIntensity > 8000 { // XXX constant XXX 
                // scan farther from brighter blobs
                scanSize = scanSize * 2   // XXX constant XXX
            }
 */          
            var startX = blob.boundingBox.min.x - scanSize
            var startY = blob.boundingBox.min.y - scanSize
            
            if startX < 0 { startX = 0 }
            if startY < 0 { startY = 0 }

            var endX = blob.boundingBox.max.x + scanSize
            var endY = blob.boundingBox.max.y + scanSize

            if endX >= width { endX = width - 1 }
            if endY >= height { endY = height - 1 }
            
            var otherBlobIsNearby = false
            
            for x in (startX ... endX) {
                for y in (startY ... endY) {
                    let blobRef = blobRefs[y*width+x]
                    if blobRef != 0,
                       blobRef != blob.id,
                       let otherBlob = blobMap[blobRef]
                    {
                        if otherBlob.adjustedSize > fx3Size(for: minNeighborSize) {
                            otherBlobIsNearby = true
                            break
                        }
                    }
                }
                if otherBlobIsNearby { break }
            }

            if !otherBlobIsNearby {
                blobMap.removeValue(forKey: blob.id)
            }
        }
    }
}
