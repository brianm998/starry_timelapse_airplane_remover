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
        let lengthOverFillAmount: Double // blobs have to have a lower value to persist
        
        public typealias Types = ArgType

        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .lengthOverFillAmount:
                return "blobs have to have a lower value to persist.\nHigher values gives more blobs"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case lengthOverFillAmount
        }

        public func isInteger(_ type: ArgType) -> Bool { false }

        public func isOptional(_ type: ArgType) -> Bool {
            return false
        }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .lengthOverFillAmount:
                return lengthOverFillAmount
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .lengthOverFillAmount:
                return Args(lengthOverFillAmount: value)
            }
        }

        
        public func intUpdate(for type: ArgType, value: Int) -> Args? { nil }
        
        public init(lengthOverFillAmount: Double) {
            self.lengthOverFillAmount = lengthOverFillAmount
        }
    }

    public func process(_ args: Args) async {
        for (id, blob) in blobMap {
            if let lineLength = await blob.lineLength(),
               let score = await blob.blobLineScore()
            {
                let ratio = lineLength/score
                if ratio > args.lengthOverFillAmount { blobMap.removeValue(forKey: id) }
            }
        }
    }
}
