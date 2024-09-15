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
public class IsolatedBlobRemover: AbstractBlobAnalyzer {

    public struct Args {
        let minNeighborSize: Int   // how big does a neighbor need to be to count?
        let scanSize: Int          // how far in each direction to look for neighbors
        let requiredNeighbors: Int // how many neighbors does each one need?

        public init(minNeighborSize: Int = 0, // how big does a neighbor need to be to count?
                    scanSize: Int = 12,     // how far in each direction to look for neighbors
                    requiredNeighbors: Int = 1) // how many neighbors does each one need?
        {
            self.minNeighborSize = minNeighborSize
            self.scanSize = scanSize
            self.requiredNeighbors = requiredNeighbors
        }
    }

    public func process(_ args: Args) {
        self.process(minNeighborSize: args.minNeighborSize,
                     scanSize: args.scanSize,
                     requiredNeighbors: args.requiredNeighbors)
    }
    
    public func process(minNeighborSize: Int = 0, // how big does a neighbor need to be to count?
                        scanSize: Int = 12,     // how far in each direction to look for neighbors
                        requiredNeighbors: Int = 1) // how many neighbors does each one need?
    {
        iterateOverAllBlobs() { _, blob in
            // only deal with small blobs
            if blob.size > 24 { // XXX constant XXX
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
                otherBlob.size > minNeighborSize
            }

            if otherBlobsNearby.count < requiredNeighbors {
                blobMap.removeValue(forKey: blob.id)
            }
        }
    }
}
