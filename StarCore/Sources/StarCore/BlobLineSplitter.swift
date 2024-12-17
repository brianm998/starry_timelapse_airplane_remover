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

// gets rid of small blobs by themselves in nowhere
public actor BlobLineSplitter {

    var blobs: [UInt16: Blob]
    let frameIndex: Int
    
    init(blobMap: [UInt16: Blob],
         frameIndex: Int) 
    {
        self.blobs = blobMap
        self.frameIndex = frameIndex
    }
    
    public func blobMap() -> [UInt16:Blob] { blobs }
    
    public struct Args: Sendable, Hashable, Equatable, Argable, Codable {

        // used here
        let minAvgDistance: Double // need avg pixel distance more than this
        let maxLineFillAmount: Double // need line fill amount less than this
        let minBlobsize: Int          // need blobs bigger than this
        
        // used by HoughLineFinder
        let maxLines: Int        // max number of lines to look at
        let maxDistance: Double  // pixels at least this far away from a line give zero score
        let minLineScore: Double // sub lines must have at least this score to be included
        let minLineCount: Int    // sub lines must have at least this number of pixels

        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .minAvgDistance:
                return "need avg pixel distance more than this"
            case .maxLineFillAmount:
                return "need line fill amount less than this"
            case .minBlobsize: 
                return "need blobs bigger than this"
            case .maxLines:
                return "max number of lines to look at"
            case .maxDistance:
                return "pixels at least this far away from a line give zero score"
            case .minLineScore:
                return "sub lines must have at least this score to be included"
            case .minLineCount:
                return "sub lines must have at least this number of pixels"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minAvgDistance
            case maxLineFillAmount
            case minBlobsize
            case maxLines
            case maxDistance
            case minLineScore
            case minLineCount
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minAvgDistance:
                return false
            case .maxLineFillAmount:
                return false
            case .minBlobsize: 
                return true
            case .maxLines:
                return true
            case .maxDistance:
                return false
            case .minLineScore:
                return false
            case .minLineCount:
                return true
            }
        }
        
        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minAvgDistance:
                return minAvgDistance
            case .maxLineFillAmount:
                return maxLineFillAmount
            case .minBlobsize: 
                return Double(minBlobsize)
            case .maxLines:
                return Double(maxLines)
            case .maxDistance:
                return maxDistance
            case .minLineScore:
                return minLineScore
            case .minLineCount:
                return Double(minLineCount)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .minAvgDistance:
                return Args(minAvgDistance: value,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: self.minBlobsize,
                            maxLines: self.maxLines,
                            maxDistance: self.maxDistance,
                            minLineScore: self.minLineScore,
                            minLineCount: self.minLineCount)

            case .maxLineFillAmount:
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: value,
                            minBlobsize: self.minBlobsize,
                            maxLines: self.maxLines,
                            maxDistance: self.maxDistance,
                            minLineScore: self.minLineScore,
                            minLineCount: self.minLineCount)

            case .minBlobsize: 
                return nil

            case .maxLines:
                return nil

            case .maxDistance:
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: self.minBlobsize,
                            maxLines: self.maxLines,
                            maxDistance: value,
                            minLineScore: self.minLineScore,
                            minLineCount: self.minLineCount)

            case .minLineScore:
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: self.minBlobsize,
                            maxLines: self.maxLines,
                            maxDistance: self.maxDistance,
                            minLineScore: value,
                            minLineCount: self.minLineCount)
                
            case .minLineCount:
                return nil
            }
        }

        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minAvgDistance:
                return nil
            case .maxLineFillAmount:
                return nil

            case .minBlobsize: 
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: value,
                            maxLines: self.maxLines,
                            maxDistance: self.maxDistance,
                            minLineScore: self.minLineScore,
                            minLineCount: self.minLineCount)

            case .maxLines:
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: self.minBlobsize,
                            maxLines: value,
                            maxDistance: self.maxDistance,
                            minLineScore: self.minLineScore,
                            minLineCount: self.minLineCount)

            case .maxDistance:
                return nil

            case .minLineScore:
                return nil

            case .minLineCount:
                return Args(minAvgDistance: self.minAvgDistance,
                            maxLineFillAmount: self.maxLineFillAmount,
                            minBlobsize: self.minBlobsize,
                            maxLines: self.maxLines,
                            maxDistance: self.maxDistance,
                            minLineScore: self.minLineScore,
                            minLineCount: value)
            }
        }
        
        public init(
          minAvgDistance: Double,
          maxLineFillAmount: Double,
          minBlobsize: Int,
          maxLines: Int = 8000,  
          maxDistance: Double = 8,
          minLineScore: Double = 12,
          minLineCount: Int = 10
        ) {
            self.minAvgDistance = minAvgDistance
            self.maxLineFillAmount = maxLineFillAmount
            self.minBlobsize = minBlobsize
            self.maxLines = maxLines
            self.maxDistance = maxDistance
            self.minLineScore = minLineScore
            self.minLineCount = minLineCount
        }
    }

    public func process(_ args: Args) async {
        for (_, blob) in blobs {

            let blobSize = await blob.size()
            let lineFillAmount = await blob.lineFillAmount()
            let avgDist = await blob.averageDistanceFromIdealLine

            if avgDist > args.minAvgDistance, // not close to the line
               // not that many pixels are on the line
               lineFillAmount < args.maxLineFillAmount, 
               blobSize > args.minBlobsize        //  big blobs only
            {
                // look and see if any pixels in this blob align with different
                // lines, and if so, split them apart into separate groups
                let lineSplitList = await blob.lineSplit(args: args)

                if lineSplitList.count > 0 {

                    // we have extra blobs to make here
                    for pixelList in lineSplitList {
                        if let newBlobId = nextIndex(from: blobs) {
                            let newBlob = Blob(Set(pixelList),
                                               id: newBlobId,
                                               frameIndex: frameIndex)

                            blobs[newBlobId] = newBlob
                        } else {
                            // cannot create a new blob (too many)
                            // so put these pixels back into the original blob
                            await blob.absorb(pixelList)
                        }
                    }
                }
            }
        }
        Log.d("frame \(frameIndex) after lineSplit, blobMap has \(blobs.count) blobs")
    }
}
