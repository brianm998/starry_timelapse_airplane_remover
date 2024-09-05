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
                        scanSize: Int = 12,     // how far in each direction to look for neighbors
                        requiredNeighbors: Int = 1) // how many neighbors does each one need?
    {
        iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if blob.adjustedSize > fx3Size(for: 24) { // XXX constant XXX
                return
            }

            
            // XXX constant XXX
               // each direction from center
/*
            var scanSize = scanSize
 
            if blob.medianIntensity > 8000 { // XXX constant XXX 
                // scan farther from brighter blobs
                scanSize = scanSize * 2   // XXX constant XXX
            }
 */          

            let otherBlobsNearby = self.directNeighbors(of: blob, scanSize: scanSize,
                                                        requiredNeighbors: requiredNeighbors)
            { otherBlob in
                otherBlob.adjustedSize > fx3Size(for: minNeighborSize)
            }

            if otherBlobsNearby.count < requiredNeighbors {
                blobMap.removeValue(forKey: blob.id)
            }
        }
    }
}
