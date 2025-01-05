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

// iterate along the blob's line, looking for another blob.
// if found, try combining them, and seeing what the line looks like then.
// if the line score is good enough, then add the combined blob
public actor LinearBlobExtender {

    let analyzer: BlobAnalyzer
    let frameIndex: Int
    
    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int,
         frameIndex: Int) async
    {
        self.frameIndex = frameIndex
        self.analyzer = await BlobAnalyzer(blobMap: blobMap,
                                           width: width,
                                           height: height,
                                           frameIndex: frameIndex)
    }

    public func blobMap() -> [UInt16:Blob] {
        analyzer.mapOfBlobs()
    }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let lineExtension: Int       // how much furter to look at the ends of the line
        let innerSearch: Int       // how far along the line to look within the bounding box
        let adjecentPixelsOnIteration: Int // how far to iterate on adject pixels
        let maxIterationCount: Int // maximum times to iterate on line improvement

        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .lineExtension:
                return "how much further to look at the ends of the line"
            case .innerSearch:
                return "how far along the line to look within the bounding box"
            case .adjecentPixelsOnIteration:
                return "how far to iterate on adject pixels"
            case .maxIterationCount:
                return "maximum times to iterate on line improvement"
            }
        }
        
        public enum ArgType: CaseIterable, Hashable {
            case lineExtension
            case innerSearch
            case adjecentPixelsOnIteration
            case maxIterationCount
        }

        public func isInteger(_ type: ArgType) -> Bool { true }

        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .lineExtension:
                return Double(lineExtension)
            case .innerSearch:
                return Double(innerSearch)
            case .adjecentPixelsOnIteration:
                return Double(adjecentPixelsOnIteration)
            case .maxIterationCount:
                return Double(maxIterationCount)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? { nil }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .lineExtension:
                return Args(lineExtension: value,
                            innerSearch: self.innerSearch,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .innerSearch:
                return Args(lineExtension: self.lineExtension,
                            innerSearch: value,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .adjecentPixelsOnIteration:
                return Args(lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            adjecentPixelsOnIteration: value,
                            maxIterationCount: self.maxIterationCount)

            case .maxIterationCount:
                return Args(lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: value)
            }
        }
        
        public init(lineExtension: Int,
                    innerSearch: Int,
                    adjecentPixelsOnIteration: Int,
                    maxIterationCount: Int)
        {
            self.lineExtension = lineExtension
            self.innerSearch = innerSearch
            self.adjecentPixelsOnIteration = adjecentPixelsOnIteration
            self.maxIterationCount = maxIterationCount
        }
    }

    let processedBlobs = ProcessedBlobs()

    public func process(_ args: Args) async {

        await analyzer.iterateOverAllBlobs() { id, blob in

            if await processedBlobs.contains(id) { return }
            await processedBlobs.insert(id)

            await process(blob: blob, args: args, furtherIterations: args.maxIterationCount)
        }
    }

    private func process(blob: Blob, args: Args, furtherIterations: Int) async {

        if furtherIterations <= 0 { return }
        
        // blobs need to have a line
        if let originZeroLine = await blob.originZeroLine {

            let intersections = await blob.boundingBox().intersections(with: originZeroLine.standardLine)
            // try to iterate lineExtension pixels off of each end of this blob,
            // looking for another blob to absorb.
            // if we find another blob:
            // - absorb it
            // - look at the line and score
            // if score is higher:
            // - keep absorbed blob, iterate again on new blob with same params
            // if score is lower:
            // - stop

            if intersections.count > 1 {
                await originZeroLine.asyncIterate(.forwards, from: intersections[0]) { x, y, orientation in
                    await self.handleIteration(of: blob,
                                               x: x,
                                               y: y,
                                               from: intersections[0],
                                               args: args,
                                               furtherIterations: furtherIterations)
                }
                await originZeroLine.asyncIterate(.backwards, from: intersections[0]) { x, y, orientation in
                    await self.handleIteration(of: blob,
                                               x: x,
                                               y: y,
                                               from: intersections[0],
                                               args: args,
                                               furtherIterations: furtherIterations)
                }
                await originZeroLine.asyncIterate(.forwards, from: intersections[1]) { x, y, orientation in
                    await self.handleIteration(of: blob,
                                               x: x,
                                               y: y,
                                               from: intersections[1],
                                               args: args,
                                               furtherIterations: furtherIterations) 
                }
                await originZeroLine.asyncIterate(.backwards, from: intersections[1]) { x, y, orientation in
                    await self.handleIteration(of: blob,
                                               x: x,
                                               y: y,
                                               from: intersections[1],
                                               args: args,
                                               furtherIterations: furtherIterations) 
                }
            }
        }
    }

    private func handleIteration(of blob: Blob,
                                 x: Int,
                                 y: Int,
                                 from originCoord: DoubleCoord,
                                 args: Args,
                                 furtherIterations: Int) async -> Bool
    {
        let distance = originCoord.distance(to: x, and: y)
        if await blob.boundingBox().contains(x: x, y: y) {
            // inside, use innerSearch
            if distance > Double(args.innerSearch) { return false }

            return await maybeAbsorb(from: blob,
                                     x: x,
                                     y: y,
                                     args: args,
                                     furtherIterations: furtherIterations)
        } else {
            // outside the bounding box, use lineExtension
            if distance > Double(args.lineExtension) { return false }

            return await maybeAbsorb(from: blob,
                                     x: x,
                                     y: y,
                                     args: args,
                                     furtherIterations: furtherIterations)
        }
        return true
    }

    private func maybeAbsorb(from blob: Blob,
                             x: Int,
                             y: Int,
                             args: Args,
                             furtherIterations: Int) async -> Bool
    {
        if let newBlob = analyzer.blob(at: x, and: y),
           newBlob != blob
        {
            if let oldScore = await blob.blobLineScore() {
                let blobCopy = await blob.copy
                await blobCopy.absorb(newBlob, always: true)
                if let newScore = await blobCopy.blobLineScore() {
                    if newScore > oldScore {
                        await analyzer.replace(blob: newBlob, with: blobCopy)
                        await processedBlobs.insert(newBlob.id)

                        // keep iterating on this blob if we can
                        await process(blob: blobCopy,
                                      args: args,
                                      furtherIterations: furtherIterations - 1)
                    }
                }
            }
            return false
        }

        return true
    }
}

