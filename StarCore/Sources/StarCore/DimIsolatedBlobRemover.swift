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

// gets rid of dimmer blobs off by themselves 
class DimIsolatedBlobRemover: AbstractBlobAnalyzer {

    // XXX adjust scan size for image resolution?
    
    public func process(scanSize: Int = 12) // how far in each direction to look for neighbors
    {
        var filteredBlobs = Array(blobMap.values)

        if filteredBlobs.count == 0 { return }

        filteredBlobs.sort { $0.medianIntensity < $1.medianIntensity }
        let midPoint = filteredBlobs.count/2
        let quarterPoint = filteredBlobs.count/4

        // median blob
        let midBlob = filteredBlobs[midPoint]

        // median blob of dimmer half
        let quarterBlob = filteredBlobs[quarterPoint]
        
        iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if blob.adjustedSize > fx3Size(for: 24) { // XXX constant XXX
                return
            }
            
            // only deal with dim blobs
            if blob.medianIntensity > midBlob.medianIntensity { return }

            // each direction from center

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
                    if let blobRef = blobRefs[y*width+x],
                       blobRef != blob.id,
                       let otherBlob = blobMap[blobRef]
                    {
                        if otherBlob.medianIntensity > quarterBlob.medianIntensity {
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
