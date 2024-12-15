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

public class BlobTrimmerWithConstants {

    var blobMap: [UInt16: Blob]
    let frameIndex: Int

    init(blobMap: [UInt16: Blob],
         frameIndex: Int) 
    {
        self.blobMap = blobMap
        self.frameIndex = frameIndex
    }

    public struct Args: Sendable, Hashable, Equatable, Argable {
        let minBlobSize: Int        // blobs smaller than this are discarded
        let minSmallBlobIntensity: UInt16? 
        let minBlobIntensity: UInt16
        let qualifierSize: Int
        let qualifierMedianIntensity: UInt16
        
        public typealias Types = ArgType
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobIntensity:
                return "blobs with intensity less than this are discarded.\nSmaller vlaues give more blobs."
            case .minSmallBlobIntensity:
                return "if set, allow smaller blobs brighter than this to persist.\nSmaller values give more blobs."
            case .minBlobSize:
                return "Blobs smaller than this are discarded.\nSmaller values give more blobs."
            case .qualifierSize:
                return "Size used for the qualifier" // XXX 
            case .qualifierMedianIntensity:
                return "Intensity used for the qualifier" // XXXx
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case minSmallBlobIntensity
            case minBlobIntensity
            case qualifierSize
            case qualifierMedianIntensity
        }

        public func isInteger(_ type: ArgType) -> Bool { true }
        
        public func isOptional(_ type: ArgType) -> Bool {
            switch type {
            case .minBlobIntensity:
                return false
            case .minSmallBlobIntensity:
                return true
            case .minBlobSize:
                return false
            case .qualifierSize:
                return false
            case .qualifierMedianIntensity:
                return false
            }
        }
        
        public func value(for type: ArgType) -> Double? {
            switch type {

            case .minBlobIntensity:
                return Double(minBlobIntensity)

            case .minSmallBlobIntensity:
                if let minSmallBlobIntensity {
                    return Double(minSmallBlobIntensity)
                } else {
                    return nil
                }
                
            case .minBlobSize:
                return Double(minBlobSize)

            case .qualifierSize:
                return Double(qualifierSize)

            case .qualifierMedianIntensity:
                return Double(qualifierMedianIntensity)
            }
        }

        public init(minBlobSize: Int,
                    minSmallBlobIntensity: UInt16? = nil,
                    minBlobIntensity: UInt16,
                    qualifierSize: Int,
                    qualifierMedianIntensity: UInt16)
        {
            self.minBlobSize = minBlobSize
            self.minSmallBlobIntensity = minSmallBlobIntensity
            self.minBlobIntensity = minBlobIntensity
            self.qualifierSize = qualifierSize
            self.qualifierMedianIntensity = qualifierMedianIntensity
        }
    }

    public func process(_ args: Args) async {
        var ret: [UInt16: Blob] = [:]
        
        for (_, blob) in blobMap {
            // anything this small is noise

            let blobIntensity = await blob.medianIntensity()
            
            if await blob.size() <= args.minBlobSize {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blob.size()) <= \(args.minBlobSize)")

                if let minSmallBlobIntensity = args.minSmallBlobIntensity {
                    if blobIntensity < minSmallBlobIntensity {
                        continue
                    } else {
                        // pass through smaller bright blobs
                    }
                } else {
                    continue
                }
            }

            if blobIntensity < args.minBlobIntensity {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of median intensity \(await blob.medianIntensity()) <= \(args.minBlobIntensity)")
                continue
            }
            
            // only keep smaller blobs if they are bright enough
            if !(await allows(blob, args: args)) {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob)")
                continue
            }

            // this blob has passed these checks, keep it for now
            ret[blob.id] = blob
        }
        blobMap = ret
    }

    fileprivate func allows(_ blob: Blob, args: Args) async -> Bool {
        let blobSize = await blob.size()
        let intensity = await blob.medianIntensity()
        
        return !(blobSize < args.qualifierSize && intensity < args.qualifierMedianIntensity)
    }
    
}
