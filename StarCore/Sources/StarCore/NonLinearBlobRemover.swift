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

// gets rid of non linear blobs
public class NonLinearBlobRemover {

    var blobMap: [UInt16: Blob]

    init(blobMap: [UInt16: Blob],
         frameIndex: Int) async
    {
        self.blobMap = blobMap
    }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minBlobSize: Int             // blobs smaller than this are ignored
        let medianIntensity: UInt16      // blob with more median intensity than this are kept
        let lengthOverFillAmount: Double // blobs have to have a lower value to persist
        let minLineFillAmount: Double    // blobs with less line fill than this are discarded
        let maxLineFillAmount: Double    // blobs with more line fill than this are kept
        
        public typealias Types = ArgType

        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobSize:
                return "blobs smaller than this are ignored"
            case .medianIntensity:
                return "blob with more median intensity than this are kept" 
            case .lengthOverFillAmount:
                return "blobs have to have a lower value to persist.\nHigher values gives more blobs"
            case .minLineFillAmount:
                return "blobs with less line fill than this are discarded"
            case .maxLineFillAmount:
                return "blobs with more line fill than this are kept"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case medianIntensity
            case lengthOverFillAmount
            case minLineFillAmount
            case maxLineFillAmount
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minBlobSize:
                return true
            case .medianIntensity:
                return true
            case .lengthOverFillAmount:
                return false
            case .minLineFillAmount:
                return false
            case .maxLineFillAmount:
                return false
            }
        }

        public func isOptional(_ type: ArgType) -> Bool {
            return false
        }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minBlobSize:
                return Double(minBlobSize)
            case .medianIntensity:
                return Double(medianIntensity)
            case .lengthOverFillAmount:
                return lengthOverFillAmount
            case .minLineFillAmount:
                return minLineFillAmount
            case .maxLineFillAmount:
                return maxLineFillAmount
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .minBlobSize:
                return nil
            case .medianIntensity:
                return nil
            case .lengthOverFillAmount:
                return Args(minBlobSize: self.minBlobSize,
                            medianIntensity: self.medianIntensity,
                            lengthOverFillAmount: value,
                            minLineFillAmount: self.minLineFillAmount,
                            maxLineFillAmount: self.maxLineFillAmount)
            case .minLineFillAmount:
                return Args(minBlobSize: self.minBlobSize,
                            medianIntensity: self.medianIntensity,
                            lengthOverFillAmount: self.lengthOverFillAmount,
                            minLineFillAmount: value,
                            maxLineFillAmount: self.maxLineFillAmount)
            case .maxLineFillAmount:
                return Args(minBlobSize: self.minBlobSize,
                            medianIntensity: self.medianIntensity,
                            lengthOverFillAmount: self.lengthOverFillAmount,
                            minLineFillAmount: self.minLineFillAmount,
                            maxLineFillAmount: value)
            }
        }

        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minBlobSize:
                return Args(minBlobSize: value,
                            medianIntensity: self.medianIntensity,
                            lengthOverFillAmount: self.lengthOverFillAmount,
                            minLineFillAmount: self.minLineFillAmount,
                            maxLineFillAmount: self.maxLineFillAmount)
            case .medianIntensity:
                return Args(minBlobSize: self.minBlobSize,
                            medianIntensity: UInt16(value),
                            lengthOverFillAmount: self.lengthOverFillAmount,
                            minLineFillAmount: self.minLineFillAmount,
                            maxLineFillAmount: self.maxLineFillAmount)
            case .lengthOverFillAmount:
                return nil
            case .minLineFillAmount:
                return nil
            case .maxLineFillAmount:
                return nil
            }
        }
        
        public init(minBlobSize: Int,
                    medianIntensity: UInt16,
                    lengthOverFillAmount: Double,
                    minLineFillAmount: Double,
                    maxLineFillAmount: Double)
        {
            self.minBlobSize = minBlobSize
            self.medianIntensity = medianIntensity
            self.lengthOverFillAmount = lengthOverFillAmount
            self.minLineFillAmount = minLineFillAmount
            self.maxLineFillAmount = maxLineFillAmount
        }
    }

    public func process(_ args: Args) async {
        for (id, blob) in blobMap {
            if await blob.size() >= args.minBlobSize,
               await blob.medianIntensity() < args.medianIntensity,
               let lineLength = await blob.lineLength(),
               let score = await blob.blobLineScore()
            {
                if score < args.minLineFillAmount {
                    blobMap.removeValue(forKey: id) 
                } else if score < args.maxLineFillAmount {
                    let ratio = lineLength/score
                    if ratio > args.lengthOverFillAmount { blobMap.removeValue(forKey: id) }
                }
            }
        }
    }
}
