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
public actor DisconnectedBlobRemover {

    fileprivate let analyzer: BlobAnalyzer
    
    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int,
         frameIndex: Int) async
    {
        analyzer = await BlobAnalyzer(blobMap: blobMap,
                                      width: width,
                                      height: height,
                                      frameIndex: frameIndex)
    }

    public func blobMap() -> [UInt16:Blob] {
        analyzer.mapOfBlobs()
    }
    
    public struct Args: Sendable {
        let scanSize: Int          // how far in each direction to look for neighbors
        let blobsSmallerThan: Int  // ignore blobs larger than this
        let blobsLargerThan: Int   // ignore blobs smaller than this
        let requiredNeighbors: Int // how many neighbors do we need?

        public init(scanSize: Int = 28,
                    blobsSmallerThan: Int = 24,
                    blobsLargerThan: Int = 0,
                    requiredNeighbors: Int = 4)
        {
            self.scanSize = scanSize
            self.blobsSmallerThan = blobsSmallerThan
            self.blobsLargerThan = blobsLargerThan
            self.requiredNeighbors = requiredNeighbors
        }
    }

    public func process(_ args: Args) async {
        let processedBlobs = ProcessedBlobs()
        await analyzer.iterateOverAllBlobs() { id, blob in
            
            if await processedBlobs.contains(id) { return }
            await processedBlobs.insert(id)
            
            // only deal with blobs in a certain size range
            let blobSize = await blob.size()
            
            if blobSize >= args.blobsSmallerThan || 
               blobSize < args.blobsLargerThan
            {
                return
            }

            // find a cloud of neighbors 
            let (neighborCloud, newProcessedBlobs) =
              await analyzer.neighborCloud(of: blob,
                                           scanSize: args.scanSize,
                                           processedBlobs: processedBlobs)

            await processedBlobs.union(with: newProcessedBlobs)

            var totalBlobSize = await blob.size()
            for neighborBlob in neighborCloud {
                totalBlobSize += await neighborBlob.size()
            }
            let averageBlobSize = Double(totalBlobSize)/Double(neighborCloud.count+1)
            
            if neighborCloud.count < args.requiredNeighbors,
               averageBlobSize < Double(args.blobsSmallerThan)
            {
                Log.i("blob of size \(await blob.size()) only has \(neighborCloud.count) neighbors")
                // remove the blob we're iterating over
                analyzer.remove(blob: blob)
                // and remove all of its (few) neighbors as well
                for blob in neighborCloud {
                    analyzer.remove(blob: blob)
                }
            } else {
                Log.i("blob of size \(await blob.size()) has \(neighborCloud.count) neighbors")
            }
        }
    }
}
