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

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minBlobSize: Int        // blobs smaller than this are discarded
        let minSmallBlobIntensity: UInt16? 
        let minBlobIntensity: UInt16
        let qualifierSize: Int
        let qualifierMedianIntensity: UInt16
        let bigBlobSize: Int
        let bigBlobMedianIntensity: UInt16
        
        public typealias Types = ArgType
        public var id: Self { self }
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobIntensity:
                return "blobs with intensity less than this are discarded.\nSmaller values give more blobs."
            case .minSmallBlobIntensity:
                return "if set, allow smaller blobs brighter than this to persist.\nSmaller values give more blobs."
            case .minBlobSize:
                return "Blobs smaller than this are discarded.\nSmaller values give more blobs."
            case .qualifierSize:
                return "Size used for the qualifier" // XXX 
            case .qualifierMedianIntensity:
                return "Intensity used for the qualifier" // XXXx
            case .bigBlobSize:
                return "blobs larger than this need to be brighter than bigBlobMedianIntensity" 
            case .bigBlobMedianIntensity:
                return "blobs dimmer than this need to be smaller than bigBlobSize" 
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case minSmallBlobIntensity
            case minBlobIntensity
            case qualifierSize
            case qualifierMedianIntensity
            case bigBlobSize
            case bigBlobMedianIntensity
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
            case .bigBlobSize:
                return false
            case .bigBlobMedianIntensity:
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
            case .bigBlobSize:
                return Double(bigBlobSize)
            case .bigBlobMedianIntensity:
                return Double(bigBlobMedianIntensity)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? { nil }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minBlobIntensity:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: UInt16(value),
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)
                
            case .minSmallBlobIntensity:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: UInt16(value),
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)
                
            case .minBlobSize:
                return Args(minBlobSize: value,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)

            case .qualifierSize:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: value,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)

            case .qualifierMedianIntensity:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: UInt16(value),
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)

            case .bigBlobSize:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: value,
                            bigBlobMedianIntensity: self.bigBlobMedianIntensity)

            case .bigBlobMedianIntensity:
                return Args(minBlobSize: self.minBlobSize,
                            minSmallBlobIntensity: self.minSmallBlobIntensity,
                            minBlobIntensity: self.minBlobIntensity,
                            qualifierSize: self.qualifierSize,
                            qualifierMedianIntensity: self.qualifierMedianIntensity,
                            bigBlobSize: self.bigBlobSize,
                            bigBlobMedianIntensity: UInt16(value))
            }
        }        
        
        public init(minBlobSize: Int,
                    minSmallBlobIntensity: UInt16? = nil,
                    minBlobIntensity: UInt16,
                    qualifierSize: Int,
                    qualifierMedianIntensity: UInt16,
                    bigBlobSize: Int = 1000,
                    bigBlobMedianIntensity: UInt16 = 1500)
        {
            self.minBlobSize = minBlobSize
            self.minSmallBlobIntensity = minSmallBlobIntensity
            self.minBlobIntensity = minBlobIntensity
            self.qualifierSize = qualifierSize
            self.qualifierMedianIntensity = qualifierMedianIntensity
            self.bigBlobSize = bigBlobSize
            self.bigBlobMedianIntensity = bigBlobMedianIntensity
        }
    }

    public func process(_ args: Args) async {
        var ret: [UInt16: Blob] = [:]
        
        for (_, blob) in blobMap {

            let blobSize = await blob.size()
            let blobIntensity = await blob.medianIntensity()
            
            if blobSize < args.qualifierSize && blobIntensity < args.qualifierMedianIntensity {
                // only keep smaller blobs if they are bright enough
                continue
            }

            // anything this small is noise
            if blobSize <= args.minBlobSize {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(await blobSize) <= \(args.minBlobSize)")

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

            if blobSize > args.bigBlobSize,
               blobIntensity < args.bigBlobMedianIntensity
            {
                continue
            }
            
            // this blob has passed these checks, keep it for now
            ret[blob.id] = blob
        }
        blobMap = ret
    }
}
