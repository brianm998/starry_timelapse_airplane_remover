import Foundation
import KHTSwift
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// trim pixels that are too far from a blobs's line
public actor BlobLineTrim {

    var blobMap: [Int32: Blob]
    let frameIndex: Int
    let maxBlobID: IntegralActor
    
    init(blobMap: [Int32: Blob], frameIndex: Int) {
        self.frameIndex = frameIndex
        self.blobMap = blobMap
        var max: Int32 = 0
        for (id, _) in blobMap { if id > max { max = id } }
        maxBlobID = IntegralActor(value: Int(max))
    }
    
    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minBlobSize: Int          // blobs smaller than this are ignored
        let minLineLength: Double     // blobs with less line length are not processed
        let trimAmount: Double        // trim  pixels further from the line than this

        public typealias Types = ArgType
        public var id: Self { self }
        
        public func description(for type: ArgType) -> String {
            switch type {
            case .minBlobSize:
                return "blobs smaller than this are ignored"
            case .minLineLength:
                return "blobs with less line length are not processed"
            case .trimAmount:
                return "trim  pixels further from the line than this"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case minLineLength
            case trimAmount
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minLineLength:
                return false
            case .trimAmount:
                return false
            case .minBlobSize:
                return true
            }
        }
        
        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minLineLength:
                return minLineLength
            case .trimAmount:
                return trimAmount
            case .minBlobSize:
                return Double(minBlobSize)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .minLineLength:
                return Args(minBlobSize: self.minBlobSize,
                            minLineLength: value,
                            trimAmount: self.trimAmount)

            case .trimAmount:
                return Args(minBlobSize: self.minBlobSize,
                            minLineLength: self.minLineLength,
                            trimAmount: value)
            case .minBlobSize:
                return nil
            }
        }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minLineLength:
                return nil
            case .trimAmount:
                return nil
            case .minBlobSize:
                return Args(minBlobSize: value,
                            minLineLength: self.minLineLength,
                            trimAmount: self.trimAmount)
            }
        }

        public init(minBlobSize: Int,
                    minLineLength: Double,
                    trimAmount: Double)
        {
            self.minBlobSize = minBlobSize
            self.minLineLength = minLineLength
            self.trimAmount = trimAmount
        }
    }

    public func process(_ args: Args) async -> [Int32:Blob] {
        let blobMap = blobMap
        self.blobMap = await Task.detached(priority: .userInitiated) {
            var blobMap = blobMap
            await withTaskGroup(of: [Blob].self) { taskGroup in
                for (_, blob) in blobMap {
                    taskGroup.addTask {
                        await StarCore.process(blob,
                                               with: args,
                                               maxBlobID: self.maxBlobID,
                                               frameIndex: self.frameIndex,
                                               maxIterations: 10)
                    }
                }
                for await newBlobs in taskGroup {
                    for newBlob in newBlobs {
                        blobMap[newBlob.id] = newBlob
                    }
                }
            }
            return blobMap
        }.value

        return self.blobMap
    }
}

// maybe break up the given blob into a set of other blobs, each of which is more linear
fileprivate func process(_ blob: Blob,
                         with args: BlobLineTrim.Args,
                         maxBlobID: IntegralActor,
                         frameIndex: Int,
                         maxIterations: Int) async -> [Blob]
{
    // ignore small blobs
    if await blob.size() > args.minBlobSize {
        // must know the line length
        if let lineLength = await blob.lineLength() {
            // line length must be big enough
            if lineLength > args.minLineLength {
                // trim that shit
                let trimmedPixels = await blob.lineTrim(by: args.trimAmount)
                if trimmedPixels.count > 0 {
                    let newBlobID = await maxBlobID.increment()
                    if newBlobID < Int32.max {

                        // iterate on this
                        
                        // make another blob from any trimmed pixels
                        let newBlob = Blob(trimmedPixels,
                                           id: Int32(newBlobID),
                                           frameIndex: frameIndex)

                        var ret = [newBlob]
                        
                        if maxIterations > 1 {
                            await ret += process(newBlob,
                                                 with: args,
                                                 maxBlobID: maxBlobID,
                                                 frameIndex: frameIndex,
                                                 maxIterations: maxIterations-1)
                        }

                        return ret
                    } else {
                        // avoid arithmetic overflow
                        Log.w("frame \(frameIndex) breaking on blob line trim because max blob id \(maxBlobID) is == UInt16.max")
                        // re-absorb the trimmed pixels into the same blob
                        await blob.absorb(trimmedPixels)
                    }
                }
            } else {
                // failing here sometimes
                Log.i("frame \(frameIndex) ignoring blob of size \(await blob.size()) \(await blob.boundingBox()) because lineLength \(lineLength) <= args.minLineLength \(args.minLineLength)")
            }
        } else {
            Log.i("frame \(frameIndex) ignoring blob of size \(await blob.size()) \(await blob.boundingBox()) because of no lineLength")
        }
    } else {
        //Log.i("frame \(frameIndex) ignoring blob of size \(await blob.size()) \(await blob.boundingBox()) because of args.minBlobSize \(args.minBlobSize)")
    }
    return []
}

