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

    public func process() {
        iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if blob.size > 24 { // XXX constant XXX
                return
            }

            // XXX constant XXX
            var scanSize = 12   // each direction from center

            if blob.medianIntensity > 8000 { // XXX constant XXX 
                // scan farther from brighter blobs
                scanSize = 24   // XXX constant XXX
            }
            
            let blobCenter = blob.boundingBox.center
            
            var startX = blobCenter.x - scanSize
            var startY = blobCenter.y - scanSize
            
            if startX < 0 { startX = 0 }
            if startY < 0 { startY = 0 }

            var endX = blobCenter.x + scanSize
            var endY = blobCenter.y + scanSize

            if endX >= width { endX = width - 1 }
            if endY >= height { endY = height - 1 }
            
            var otherBlobIsNearby = false
            
            for x in (startX ... endX) {
                for y in (startY ... endY) {
                    if let blobRef = blobRefs[y*width+x],
                       blobRef != blob.id
                    {
                        otherBlobIsNearby = true
                        break
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
