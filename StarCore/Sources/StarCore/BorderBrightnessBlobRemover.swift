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

public actor BorderBrightnessBlobRemover {

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
        let maxBrightness: Double
        let medianIntensityFloor: UInt16
        
        public typealias Types = ArgType

        public func description(for type: ArgType) -> String {
            switch type {
            case .maxBrightness:
                return "Blobs with border brightness vs the original image less than this "
            case .medianIntensityFloor:
                return "Blobs with median intensity greater than this"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case maxBrightness
            case medianIntensityFloor
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .maxBrightness:
                return false
            case .medianIntensityFloor:
                return true
            }
        }

        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .maxBrightness:
                return maxBrightness
            case .medianIntensityFloor:
                return Double(medianIntensityFloor)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .maxBrightness:
                return Args(maxBrightness: value,
                            medianIntensityFloor: self.medianIntensityFloor)
            case .medianIntensityFloor:
                return nil
            }
        }

        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .maxBrightness:
                return nil
            case .medianIntensityFloor:
                return Args(maxBrightness: self.maxBrightness,
                            medianIntensityFloor: UInt16(value))
            }
        }
        
        public init(maxBrightness: Double,
                    medianIntensityFloor: UInt16)
        {
            self.maxBrightness = maxBrightness
            self.medianIntensityFloor = medianIntensityFloor
        }
    }

    public func process(_ args: Args, originalImage: PixelatedImage) async {

        var ret: [UInt16: Blob] = [:]

        for (_, blob) in blobMap {
            let medianIntensity = await blob.medianIntensity()
            if await originalImage.borderBrightness(of: blob.pixels) < args.maxBrightness ||
                 medianIntensity > args.medianIntensityFloor
            {
                ret[blob.id] = blob
            }
        }
        
        blobMap = ret
    }
}
