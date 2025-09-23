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

    private var blobMap: [Int32: Blob]
    private let frameIndex: Int
    
    init(blobMap: [Int32: Blob],
         frameIndex: Int)
    {
        self.blobMap = blobMap
        self.frameIndex = frameIndex
    }
    
    public func blobMap() async -> [Int32:Blob] { blobMap }
    
    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minBlobSize: Int       // blobs smaller than this are ignored
        let intensityFloor: UInt16 // all blobs above this are ignored
        
        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobSize:
                return "blobs smaller than this are discarded"
            case .intensityFloor:
                return "all blobs less intense than this are discarded"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case intensityFloor
        }

        public func isInteger(_ type: ArgType) -> Bool { true }
        
        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minBlobSize:
                return Double(minBlobSize)
            case .intensityFloor:
                return Double(intensityFloor)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? { nil }

        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {

            case .minBlobSize:
                return Args(minBlobSize: value,
                            intensityFloor: self.intensityFloor)

            case .intensityFloor:
                return Args(minBlobSize: self.minBlobSize,
                            intensityFloor: UInt16(value))
            }
        }

        public init(minBlobSize: Int = 24, intensityFloor: UInt16 = UInt16.max) {
            self.minBlobSize = minBlobSize
            self.intensityFloor = intensityFloor
        }
    }

    public func process(_ args: Args) async {
        for (_, blob) in blobMap {
            let (size, medianIntensity) = await (blob.size(), blob.medianIntensity())
            if  size <= args.minBlobSize ||
                medianIntensity < args.intensityFloor
            {
                blobMap.removeValue(forKey: blob.id)
            }
        }
    }
}
