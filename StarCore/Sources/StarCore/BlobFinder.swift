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
public class BlobFinder {

    public init() { }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable {
        let minPixelIntensity: UInt16
        let minContrast: Double
        
        public typealias Types = ArgType
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .minPixelIntensity:
                return "Pixels in the subtraction image with less changed intensity than this cannot start blobs.\nLower values give more blobs."
            case .minContrast: 
                return """
                  blobs can grow until they get this
                  percentage darker than their seed pixel
                  larger values make any individiual blob bigger,
                  and may increase the total number of blobs due to their size

                  how close to zero (in percentage) can the intensity of pixels decrease before
                  being left out of a blob
                  zero means that only pixels of minimumLocalMaximum or higher will be in blobs
                  50 means that all pixels half as bright or more than the maximum will be in a blob
                  100 means that all pixels will be in a blob
                  """
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minPixelIntensity
            case minContrast
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minPixelIntensity:
                return true
            case .minContrast:
                return false
            }
        }
        
        public func isOptional(_ type: ArgType) -> Bool { false }

        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minPixelIntensity:
                return Double(minPixelIntensity)
            case .minContrast:
                return minContrast
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .minPixelIntensity:
                return nil
            case .minContrast:
                return Args(minPixelIntensity: self.minPixelIntensity,
                            minContrast: value)
            }
        }

        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minPixelIntensity:
                return Args(minPixelIntensity: UInt16(value),
                            minContrast: self.minContrast)
            case .minContrast:
                return nil
            }
        }

        public init(minPixelIntensity: UInt16,
                    minContrast: Double)
        {
            self.minPixelIntensity = minPixelIntensity
            self.minContrast = minContrast
        }
    }

    public func process(_ args: Args,
                        subtractionArray: [UInt16],
                        originalImage: PixelatedImage,
                        frame: FrameAirplaneRemover) async -> [UInt16: Blob]
    {
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or dots in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        let blobber = await FullFrameBlobber(config: await frame.configManager.config(),
                                             args: args,
                                             imageWidth: frame.width,
                                             imageHeight: frame.height,
                                             subtractionPixelData: subtractionArray,
                                             originalImage: originalImage,
                                             frameIndex: frame.frameIndex,
                                             neighborType: .eight)//.fourCardinal

        blobber.sortPixels()
        
        await frame.set(state: .detectingBlobs)
        
        // run the blobber
        await blobber.process()
        
        Log.d("frame \(frame.frameIndex) blobber done")

        return blobber.blobMap
    }
}
