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

// recurse on finding nearby blobs to isolate groups of neighbors as a set
// use the size of the neighbor set to determine if we keep a blob or not
class DisconnectedBlobRemover: AbstractBlobAnalyzer {

    public func process(scanSize: Int = 28,    // how far in each direction to look for neighbors
                        blobsSmallerThan: Int = 24, // ignore blobs larger than this
                        blobsLargerThan: Int = 0,  // ignore blobs smaller than this
                        requiredNeighbors: Int = 4) // how many neighbors do we need?
    {
        var processedBlobs: Set<UInt16> = []
        iterateOverAllBlobs() { id, blob in
            if processedBlobs.contains(id) { return }
            processedBlobs.insert(id)
            
            // only deal with blobs in a certain size range
            if blob.size >= blobsSmallerThan || 
               blob.size < blobsLargerThan
            {
                return
            }

            // recursive find all neighbors 
            let (recursiveNeighbors, newProcessedBlobs) =
              recursiveNeighbors(of: blob,
                                 scanSize: scanSize,
                                 processedBlobs: processedBlobs)

            processedBlobs = processedBlobs.union(newProcessedBlobs)

            let totalBlobSize = recursiveNeighbors.map { $0.size }.reduce(0, +) + blob.size
            let averageBlobSize = Double(totalBlobSize)/Double(recursiveNeighbors.count+1)
            
            if recursiveNeighbors.count < requiredNeighbors,
               averageBlobSize < Double(blobsSmallerThan)
            {
                Log.i("blob of size \(blob.size) only has \(recursiveNeighbors.count) neighbors")
                // remove the blob we're iterating over
                blobMap.removeValue(forKey: blob.id)
                // and remove all of its (few) neighbors as well
                for blob in recursiveNeighbors {
                    blobMap.removeValue(forKey: blob.id)
                }
            } else {
                Log.i("blob of size \(blob.size) has \(recursiveNeighbors.count) neighbors")
            }
        }
    }
}
