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

// A wrapper for the FullFrameBlobber that has Argable Args so it can easily run in the
// BlobProcessor and be exposed to the gui.
public class BlobFinder {

    public init() { }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minPixelIntensity: UInt16
        let startContrastSize: Int
        let endContrastSize: Int
        let startMinContrast: Double
        let endMinContrast: Double
        
        public var id: Self { self }

        public typealias Types = ArgType
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .minPixelIntensity:
                return "Pixels in the subtraction image with less changed intensity than this cannot start blobs.\nLower values give more blobs."
            case .startContrastSize:
                return "the blob size at which the contrast change starts"
            case .endContrastSize:
                return "the blob size at which the contrast change ends"
            case .startMinContrast:
                return """
                  Blobs smaller than startContrastSize will use this value as their contrast threshold.
                  
                  blobs can grow until they get this
                  percentage darker than their seed pixel
                  larger values make any individiual blob bigger,
                  and may increase the total number of blobs due to their size

                  How close to zero (in percentage) can the intensity of pixels decrease before
                  being left out of a blob.
                  zero means that only pixels of minimumLocalMaximum or higher will be in blobs
                  50 means that all pixels half as bright or more than the maximum will be in a blob
                  100 means that all pixels will be in a blob
                  """
            case .endMinContrast: 
                return """
                  Blobs that have grown to be larger than endContrastSize will use this value as their contrast threshold.

                  Blobs that are sized between startContrastSize and endContrastSize will use a linear interpolation of startContrastSize and endContrastSize, according to their size.
                  """
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minPixelIntensity
            case startContrastSize
            case endContrastSize
            case startMinContrast
            case endMinContrast
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minPixelIntensity:
                return true
            case .startContrastSize:
                return true
            case .endContrastSize:
                return true
            case .startMinContrast:
                return false
            case .endMinContrast:
                return false
            }
        }
        
        public func isOptional(_ type: ArgType) -> Bool { false }

        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minPixelIntensity:
                return Double(minPixelIntensity)
            case .startContrastSize:
                return Double(startContrastSize)
            case .endContrastSize:
                return Double(endContrastSize)
            case .startMinContrast:
                return startMinContrast
            case .endMinContrast:
                return endMinContrast
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .minPixelIntensity:
                return nil
            case .startContrastSize:
                return nil
            case .endContrastSize:
                return nil
            case .startMinContrast:
                return Args(minPixelIntensity: self.minPixelIntensity,
                            startContrastSize: self.startContrastSize,
                            endContrastSize: self.endContrastSize,
                            startMinContrast: value,
                            endMinContrast: self.endMinContrast)
            case .endMinContrast:
                return Args(minPixelIntensity: self.minPixelIntensity,
                            startContrastSize: self.startContrastSize,
                            endContrastSize: self.endContrastSize,
                            startMinContrast: self.startMinContrast,
                            endMinContrast: value)
            }
        }

        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minPixelIntensity:
                return Args(minPixelIntensity: UInt16(value),
                            startContrastSize: self.startContrastSize,
                            endContrastSize: self.endContrastSize,
                            startMinContrast: self.startMinContrast,
                            endMinContrast: self.endMinContrast)

            case .startContrastSize:
                return Args(minPixelIntensity: self.minPixelIntensity,
                            startContrastSize: value,
                            endContrastSize: self.endContrastSize,
                            startMinContrast: self.startMinContrast,
                            endMinContrast: self.endMinContrast)

            case .endContrastSize:
                return Args(minPixelIntensity: self.minPixelIntensity,
                            startContrastSize: self.startContrastSize,
                            endContrastSize: value,
                            startMinContrast: self.startMinContrast,
                            endMinContrast: self.endMinContrast)
                
            case .startMinContrast:
                return nil
            case .endMinContrast:
                return nil
            }
        }

        public init(minPixelIntensity: UInt16,
                    startContrastSize: Int,
                    endContrastSize: Int,
                    startMinContrast: Double,
                    endMinContrast: Double)
        {
            self.minPixelIntensity = minPixelIntensity
            self.startContrastSize = startContrastSize
            self.endContrastSize = endContrastSize
            self.startMinContrast = startMinContrast
            self.endMinContrast = endMinContrast
        }
    }

    public func process(_ args: Args,
                        subtractionArray: [UInt16],
                        originalImage: PixelatedImage,
                        frame: FrameAirplaneRemover,
                        within bounds: BoundingBox? = nil,
                        startingBlobID: UInt16 = 1
    ) async -> [UInt32: Blob] {
        // detect blobs of difference in brightness in the subtraction array
        // airplanes show up as lines or dots in a line
        // because the image subtracted from this frame had the sky aligned,
        // the ground may get moved, and therefore may contain blobs as well.
        Log.i("frame \(frame.frameIndex) startingBlobID \(startingBlobID)")
        let blobber = await FullFrameBlobber(
          config: await frame.configManager.config(),
          args: args,
          imageWidth: frame.width,
          imageHeight: frame.height,
          within: bounds,
          subtractionPixelData: subtractionArray,
          originalImage: originalImage,
          frameIndex: frame.frameIndex,
          neighborType: .eight,//.fourCardinal
          startingBlobID: startingBlobID
        )

        blobber.sortPixels()
        
        await frame.set(state: .detectingBlobs)
        
        // run the blobber
        await blobber.process()
        
        Log.d("frame \(frame.frameIndex) blobber done")

        return blobber.blobMap
    }
}
