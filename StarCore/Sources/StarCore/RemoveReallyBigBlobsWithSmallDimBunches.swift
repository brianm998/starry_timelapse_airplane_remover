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

// any really big blobs with lots of small bunches that are dim can go away
public actor RemoveReallyBigBlobsWithSmallDimBunches {

    private var blobMap: [UInt16: Blob]
    private let frameIndex: Int
    
    init(blobMap: [UInt16: Blob],
         frameIndex: Int) 
    {
        self.blobMap = blobMap
        self.frameIndex = frameIndex
    }
    
    public func blobMap() async -> [UInt16:Blob] { blobMap }
    
    public struct Args: Sendable, Hashable, Equatable, Argable, Codable {
        let minBlobSize: Int
        let minBunchCount: Int
        let maxBunchSize: Int
        let intensityCeiling: UInt16
        let removePixelsDimmerThan: UInt16
        
        public typealias Types = ArgType

        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobSize:
                return "Blobs smaller than this are ignored"
            case .minBunchCount:
                return "Blobs with smaller bunch counts are ignored"
            case .maxBunchSize:
                return "Blobs with a median bunch size larger than this are ignored"
            case .intensityCeiling:
                return "Blobs with a greater median intensity are ignored"
            case .removePixelsDimmerThan:
                return "If a blob passes the above test, any pixels in that blob that are dimmer than this value are removed from this blob."
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case minBunchCount
            case maxBunchSize
            case intensityCeiling
            case removePixelsDimmerThan
        }

        public func isInteger(_ type: ArgType) -> Bool { true }

        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minBlobSize:
                return Double(minBlobSize)
            case .minBunchCount:
                return Double(minBunchCount)
            case .maxBunchSize:
                return Double(maxBunchSize)
            case .intensityCeiling:
                return Double(intensityCeiling)
            case .removePixelsDimmerThan:
                return Double(removePixelsDimmerThan)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? { nil }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minBlobSize:
                return Args(minBlobSize: value,
                            minBunchCount: self.minBunchCount,
                            maxBunchSize: self.maxBunchSize,
                            intensityCeiling: self.intensityCeiling,
                            removePixelsDimmerThan: self.removePixelsDimmerThan)
                
            case .minBunchCount:
                return Args(minBlobSize: self.minBlobSize,
                            minBunchCount: value,
                            maxBunchSize: self.maxBunchSize,
                            intensityCeiling: self.intensityCeiling,
                            removePixelsDimmerThan: self.removePixelsDimmerThan)

            case .maxBunchSize:
                return Args(minBlobSize: self.minBlobSize,
                            minBunchCount: self.minBunchCount,
                            maxBunchSize: value,
                            intensityCeiling: self.intensityCeiling,
                            removePixelsDimmerThan: self.removePixelsDimmerThan)

            case .intensityCeiling:
                return Args(minBlobSize: self.minBlobSize,
                            minBunchCount: self.minBunchCount,
                            maxBunchSize: self.maxBunchSize,
                            intensityCeiling: UInt16(value),
                            removePixelsDimmerThan: self.removePixelsDimmerThan)

            case .removePixelsDimmerThan:
                return Args(minBlobSize: self.minBlobSize,
                            minBunchCount: self.minBunchCount,
                            maxBunchSize: self.maxBunchSize,
                            intensityCeiling: self.intensityCeiling,
                            removePixelsDimmerThan: UInt16(value))
            }
        }

        public init(minBlobSize: Int = 1000,
                    minBunchCount: Int = 100,
                    maxBunchSize: Int = 10,
                    intensityCeiling: UInt16 = 6000,
                    removePixelsDimmerThan: UInt16 = 6000)
        {
            self.minBlobSize = minBlobSize
            self.minBunchCount = minBunchCount
            self.maxBunchSize = maxBunchSize
            self.intensityCeiling = intensityCeiling
            self.removePixelsDimmerThan = removePixelsDimmerThan
        }
    }

    public func process(_ args: Args) async {

        var ret: [UInt16: Blob] = [:]

        for (_, blob) in blobMap {
            let blobSize = await blob.size()

            if blobSize > args.minBlobSize,
               await blob.bunchCount() > args.minBunchCount,
               await blob.medianBunchSize() < args.maxBunchSize,
               await blob.medianIntensity() < args.intensityCeiling
            {
                //Log.d("frame \(frame.frameIndex) dumping blob \(blob) of size \(blobSize) bunch count \(await blob.bunchCount()) medianBunchSize \(await blob.medianBunchSize()) medianIntensity \(await blob.medianIntensity())")
                // try processing this further by getting rid of dim blobs?
                // for now just kick it out
                await blob.removePixels(dimmerThan: args.removePixelsDimmerThan)
                ret[blob.id] = blob
            } else {
                ret[blob.id] = blob
            }
        }
        blobMap = ret
    }
}
