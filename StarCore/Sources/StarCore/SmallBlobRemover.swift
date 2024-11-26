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
public actor SmallBlobRemover {

    private var blobMap: [UInt16: Blob]
    private let frameIndex: Int
    
    init(blobMap: [UInt16: Blob],
         frameIndex: Int) 
    {
        self.blobMap = blobMap
        self.frameIndex = frameIndex
    }
    
    public func blobMap() async -> [UInt16:Blob] { blobMap }
    
    public struct Args: Sendable {
        let minBlobSize: Int       // blobs smaller than this are ignored
        let intensityFloor: UInt16 // all blobs above this are ignored
        
        public init(minBlobSize: Int = 24, intensityFloor: UInt16 = UInt16.max) {
            self.minBlobSize = minBlobSize
            self.intensityFloor = intensityFloor
        }
    }

    public func process(_ args: Args) async {
        for (_, blob) in blobMap {
            if await blob.size() <= args.minBlobSize,
               await blob.medianIntensity() < args.intensityFloor
            {
                blobMap.removeValue(forKey: blob.id)
            }
        }
    }
}
