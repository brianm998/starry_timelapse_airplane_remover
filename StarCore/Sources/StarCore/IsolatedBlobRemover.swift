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
public actor IsolatedBlobRemover {

    let analyzer: BlobAnalyzer
    
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
        let minNeighborSize: Int   // how big does a neighbor need to be to count?
        let scanSize: Int          // how far in each direction to look for neighbors
        let requiredNeighbors: Int // how many neighbors does each one need?
        let minBlobSize: Int       // blobs smaller than this are ignored

        public init(minNeighborSize: Int = 0,
                    scanSize: Int = 12,     
                    requiredNeighbors: Int = 1,
                    minBlobSize: Int = 24)
        {
            self.minNeighborSize = minNeighborSize
            self.scanSize = scanSize
            self.requiredNeighbors = requiredNeighbors
            self.minBlobSize = minBlobSize
        }
    }

    public func process(_ args: Args) async {
        await analyzer.iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if await blob.size() > args.minBlobSize { return }
            
            let otherBlobsNearby = await analyzer.directNeighbors(of: blob, scanSize: args.scanSize,
                                                                  requiredNeighbors: args.requiredNeighbors)
            { otherBlob in
                await otherBlob.size() > args.minNeighborSize
            }

            if otherBlobsNearby.count < args.requiredNeighbors {
                analyzer.remove(blob: blob)
            }
        }
    }
}
