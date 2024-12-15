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
public class SmallDimBlobRemover {

    var blobMap: [UInt16: Blob]
    let frameIndex: Int

    init(blobMap: [UInt16: Blob],
         frameIndex: Int) 
    {
        self.blobMap = blobMap
        self.frameIndex = frameIndex
    }

    public struct Args: Sendable, Hashable, Equatable, Argable {
        let sizeFloor: Int?         // if set with intenisty floor, then blobs that 
        let intensityFloor: UInt16? // are smaller and less intense will be discarded
        
        public typealias Types = ArgType
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .sizeFloor:
                return "if set with intenisty floor, then blobs that" // XXX fix this
            case .intensityFloor:
                return "are smaller and less intense will be discarded"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case sizeFloor
            case  intensityFloor
        }

        public func isInteger(_ type: ArgType) -> Bool { true }
        
        public func isOptional(_ type: ArgType) -> Bool { true }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .sizeFloor:
                if let sizeFloor {
                    return Double(sizeFloor)
                } else {
                    return nil
                }
            case .intensityFloor:
                if let intensityFloor {
                    return Double(intensityFloor)
                } else {
                    return nil
                }
            }
        }

        public init(sizeFloor: Int? = nil,
                    intensityFloor: UInt16? = nil)
        {
            self.sizeFloor = sizeFloor
            self.intensityFloor = intensityFloor
        }
    }

    public func process(_ args: Args) async {
        var ret: [UInt16: Blob] = [:]

        let blobberMinBlobSize = await constants.blobberMinBlobSize
        
        for (_, blob) in blobMap {
            let blobSize = await blob.size()
            if blobSize <= blobberMinBlobSize {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(constants.blobberMinBlobSize)")
                continue
            }
            if let sizeFloor = args.sizeFloor,
               let intensityFloor = args.intensityFloor
            {
                let blobIntensity = await blob.medianIntensity()
                if blobSize < sizeFloor,
                   blobIntensity < intensityFloor
                {
                    continue
                }
            }
            
            // this blob has passed these checks, keep it for now
            ret[blob.id] = blob
        }
        blobMap = ret
    }
}
