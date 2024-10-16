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
public actor DimIsolatedBlobRemover {

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
    
    public func blobMap() async -> [UInt16:Blob] {
        analyzer.mapOfBlobs()
    }
    
    public struct Args: Sendable {
        let scanSize: Int // how far in each direction to look for neighbors
        let requiredNeighbors: Int // how many neighbors do we need to find?
        let minBlobSize: Int       // blobs smaller than this are ignored
        
        public init(scanSize: Int = 12,
                    requiredNeighbors: Int = 1,
                    minBlobSize: Int = 24)
        {
            self.scanSize = scanSize
            self.requiredNeighbors = requiredNeighbors
            self.minBlobSize = minBlobSize
        }
    }

    public func process(_ args: Args) async {
        let filteredBlobs = analyzer.blobs()

        if filteredBlobs.count == 0 { return }

        var medianIntensities = await medianIntensities(of: filteredBlobs)
        
        medianIntensities.sort { $0 < $1 }
        
        let midPoint = filteredBlobs.count/2
        let quarterPoint = filteredBlobs.count/4

        // median blob
        let midBlob = filteredBlobs[midPoint]

        // median blob of dimmer half
        let quarterBlob = filteredBlobs[quarterPoint]

        let quarterBlobMedianIntensity = await quarterBlob.medianIntensity()
        let midBlobMedianIntensity = await midBlob.medianIntensity()
        
        await analyzer.iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if await blob.size() > args.minBlobSize { return }
            
            // only deal with dim blobs
            if await blob.medianIntensity() > midBlobMedianIntensity { return }

            // each direction from center
            let otherBlobsNearby = await analyzer.directNeighbors(of: blob,
                                                                  scanSize: args.scanSize,
                                                                  requiredNeighbors: args.requiredNeighbors)
            { otherBlob in
                await otherBlob.medianIntensity() > quarterBlobMedianIntensity
            }
                                                          
            if otherBlobsNearby.count < args.requiredNeighbors {
                analyzer.remove(blob: blob)
            }
        }
    }
}
