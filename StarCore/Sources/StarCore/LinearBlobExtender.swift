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

    public func blobMap() async -> [UInt16:Blob] {
        await analyzer.mapOfBlobs()
    }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let minBlobSize: Int    // blobs smaller than this are ignored
        let lineExtension: Int       // how much furter to look at the ends of the line
        let innerSearch: Int       // how far along the line to look within the bounding box
        let maxIterationCount: Int // maximum times to iterate on line improvement
        let scoreMultiplier: Double
        let sideIterationPixels: Int // how far to iterate on each side of the line

        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .sideIterationPixels:
                return "how far to iterate on each side of the line"
            case .minBlobSize:
                return "blobs smaller than this are ignored"
            case .lineExtension:
                return "how much further to look at the ends of the line"
            case .innerSearch:
                return "how far along the line to look within the bounding box"
            case .maxIterationCount:
                return "maximum times to iterate on line improvement"
            case .scoreMultiplier:
                return "multipler to allow smaller scores to still count.  Larger values give larger blobs"
            }
        }
        
        public enum ArgType: CaseIterable, Hashable {
            case minBlobSize
            case lineExtension
            case innerSearch
            case maxIterationCount
            case scoreMultiplier
            case sideIterationPixels
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .scoreMultiplier:
                return false
            default:
                return true
            }
        }

        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .minBlobSize:
                return Double(minBlobSize)
            case .lineExtension:
                return Double(lineExtension)
            case .innerSearch:
                return Double(innerSearch)
            case .maxIterationCount:
                return Double(maxIterationCount)
            case .scoreMultiplier:
                return scoreMultiplier
            case .sideIterationPixels:
                return Double(sideIterationPixels)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .scoreMultiplier:
                return Args(minBlobSize: self.minBlobSize,
                            lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            maxIterationCount: self.maxIterationCount,
                            scoreMultiplier: value,
                            sideIterationPixels: self.sideIterationPixels)
            default:
                return nil
            }
        }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .minBlobSize:
                return Args(minBlobSize: value,
                            lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            maxIterationCount: self.maxIterationCount,
                            scoreMultiplier: self.scoreMultiplier,
                            sideIterationPixels: self.sideIterationPixels)
            case .lineExtension:
                return Args(minBlobSize: self.minBlobSize,
                            lineExtension: value,
                            innerSearch: self.innerSearch,
                            maxIterationCount: self.maxIterationCount,
                            scoreMultiplier: self.scoreMultiplier,
                            sideIterationPixels: self.sideIterationPixels)

            case .innerSearch:
                return Args(minBlobSize: self.minBlobSize,
                            lineExtension: self.lineExtension,
                            innerSearch: value,
                            maxIterationCount: self.maxIterationCount,
                            scoreMultiplier: self.scoreMultiplier,
                            sideIterationPixels: self.sideIterationPixels)

            case .maxIterationCount:
                return Args(minBlobSize: self.minBlobSize,
                            lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            maxIterationCount: value,
                            scoreMultiplier: self.scoreMultiplier,
                            sideIterationPixels: self.sideIterationPixels)
            case .scoreMultiplier:
                return nil
            case .sideIterationPixels:
                return Args(minBlobSize: self.minBlobSize,
                            lineExtension: self.lineExtension,
                            innerSearch: self.innerSearch,
                            maxIterationCount: self.maxIterationCount,
                            scoreMultiplier: self.scoreMultiplier,
                            sideIterationPixels: value)
            }
        }
        
        public init(minBlobSize: Int,
                    lineExtension: Int,
                    innerSearch: Int,
                    maxIterationCount: Int,
                    scoreMultiplier: Double,
                    sideIterationPixels: Int)
        {
            self.minBlobSize = minBlobSize
            self.lineExtension = lineExtension
            self.innerSearch = innerSearch
            self.maxIterationCount = maxIterationCount
            self.scoreMultiplier = scoreMultiplier
            self.sideIterationPixels = sideIterationPixels
        }
    }

    /*
     - use single static blob map and image for all
     - use processedBlobs to keep from doing the same thing twice
     */
    
    public func process(_ args: Args) async {

        let blobImage = await analyzer.pixelatedImage
        let blobMap = await analyzer.mapOfBlobs()
        let processedBlobs = ProcessedBlobs()

        await withTaskGroup(of: Void.self) { taskGroup in
            for (id, blob) in blobMap {
                if await processedBlobs.contains(id) { return }
                await processedBlobs.insert(id)
                if await blob.size() < args.minBlobSize { return }
                
                taskGroup.addTask { [self] in
                    let data = Data(args: args,
                                    blobMap: blobMap,
                                    blobImage: blobImage,
                                    iterationBlob: .init(),
                                    processedBlobs: processedBlobs,
                                    analyzer: analyzer)
                    
                    await StarCore.process(blob: blob,
                                           data: data,
                                           furtherIterations: args.maxIterationCount)
                }
            }
            await taskGroup.waitForAll()
        }
    }

    // used for passing processing data around to different methods
    final class Data: Sendable {
        let args: LinearBlobExtender.Args
        let blobMap: [UInt16:Blob]
        let blobImage: PixelatedImage
        let iterationBlob: OptionalActor<Blob>
        let processedBlobs: ProcessedBlobs
        let analyzer: BlobAnalyzer

        public init(args: LinearBlobExtender.Args,
                    blobMap: [UInt16:Blob],
                    blobImage: PixelatedImage,
                    iterationBlob: OptionalActor<Blob>,
                    processedBlobs: ProcessedBlobs,
                    analyzer: BlobAnalyzer)
        {
            self.args = args
            self.blobMap = blobMap
            self.blobImage = blobImage
            self.iterationBlob = iterationBlob
            self.processedBlobs = processedBlobs
            self.analyzer = analyzer
        }
    }
}

fileprivate func process(blob: Blob,
                         data: LinearBlobExtender.Data,
                         furtherIterations: Int) async
{

    if furtherIterations <= 0 { return }

    //Log.d("frame \(frameIndex) processing blob \(blob) furtherIterations \(furtherIterations)")

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
            let blobSize = await blob.size()
            //Log.d("frame \(frameIndex) processing blob \(blob) size \(blobSize) intersections.count \(intersections.count)")
            //Log.d("frame \(frameIndex) processing blob \(blob) iterating forwards from intersection 0")
            await originZeroLine.asyncIterate(.forwards, from: intersections[0]) { x, y, orientation in
                await handleIteration(x: x, y: y,
                                      from: intersections[0],
                                      data: data,
                                      furtherIterations: furtherIterations)
            }
            //Log.d("frame \(frameIndex) processing blob \(blob) iterating backwards from intersection 0")
            await originZeroLine.asyncIterate(.backwards, from: intersections[0]) { x, y, orientation in
                await handleIteration(x: x, y: y,
                                      from: intersections[0],
                                      data: data,
                                      furtherIterations: furtherIterations)
            }
            //Log.d("frame \(frameIndex) processing blob \(blob) iterating forwards from intersection 1")
            await originZeroLine.asyncIterate(.forwards, from: intersections[1]) { x, y, orientation in
                await handleIteration(x: x, y: y,
                                      from: intersections[1],
                                      data: data,
                                      furtherIterations: furtherIterations) 
            }
            //Log.d("frame \(frameIndex) processing blob \(blob) iterating backwards from intersection 1")
            await originZeroLine.asyncIterate(.backwards, from: intersections[1]) { x, y, orientation in
                await handleIteration(x: x, y: y,
                                      from: intersections[1],
                                      data: data,
                                      furtherIterations: furtherIterations) 
            }
        }
    }
}

fileprivate func handleIteration(x: Int,
                                 y: Int,
                                 from originCoord: DoubleCoord,
                                 data: LinearBlobExtender.Data,
                                 furtherIterations: Int) async -> Bool
{
    if let _iterationBlob = await data.iterationBlob.value {
        let distance = originCoord.distance(to: x, and: y)
        if await _iterationBlob.boundingBox().contains(x: x, y: y) {
            //Log.d("frame \(frameIndex) processing blob \(_iterationBlob) @ [\(x), \(y)] distance \(distance) inside bounding box extension \(data.args.innerSearch)")
            // inside, use innerSearch
            if distance > Double(data.args.innerSearch) { return false }

            return await maybeAbsorb(x: x,
                                     y: y,
                                     data: data,
                                     furtherIterations: furtherIterations)
        } else {
            //Log.d("frame \(frameIndex) processing blob \(_iterationBlob) @ [\(x), \(y)] distance \(distance) outside bounding box extension \(data.args.lineExtension)")
            // outside the bounding box, use lineExtension
            if distance > Double(data.args.lineExtension) { return false }

            return await maybeAbsorb(x: x,
                                     y: y,
                                     data: data,
                                     furtherIterations: furtherIterations)
        }
        return true
    }
    return false
}


fileprivate func maybeAbsorb(x: Int,
                             y: Int,
                             data: LinearBlobExtender.Data,
                             furtherIterations: Int) async -> Bool
{
    guard let _iterationBlob = await data.iterationBlob.value else { return false }

    let intensity = data.blobImage.intensity(atX: x, andY: y)
    
    if intensity < UInt16.max,
       let newBlob = data.blobMap[UInt16(intensity)],
       newBlob != _iterationBlob
    {
        //Log.d("frame \(frameIndex) processing blob \(_iterationBlob) @ [\(x), \(y)] found other blob \(newBlob)")
        if let oldScore = await _iterationBlob.blobLineScore() {
            let blobCopy = await _iterationBlob.copy
            if await blobCopy.absorb(newBlob, always: true) {

                /*

                 XXX maybe check the original line as well?
                 sometimes the new score is lower, but we should still combine them :(
                 
                 */

                let newBlobSize = await newBlob.size()
                let blobSize = await _iterationBlob.size()
                
                if let newLine = await blobCopy.line,
                   let newScore = await blobCopy.blobLineScore()
                {
                    //Log.d("frame \(frameIndex) processing blob \(_iterationBlob) @ [\(x), \(y)] oldScore \(oldScore) newScore \(newScore)")
                    if newScore*data.args.scoreMultiplier > oldScore {
                        await data.analyzer.replace(blob: newBlob, with: blobCopy)
                        await data.analyzer.update(blob: blobCopy)
                        await data.processedBlobs.insert(newBlob.id)
                        await data.iterationBlob.set(blobCopy)
                        
                        let copySize = await blobCopy.size()
                        
                        //Log.d("frame \(frameIndex) processing blob \(iterationBlob) @ [\(x), \(y)] size \(blobSize) did absorb other blob size \(newBlobSize) resulting in size \(copySize)")
                        
                        // keep iterating on this blob if we can
                        await process(blob: blobCopy,
                                      data: data,
                                      furtherIterations: furtherIterations - 1)
                    } else {
                        //Log.d("frame \(frameIndex) processing blob \(iterationBlob) @ [\(x), \(y)] FUCK 3")
                    }
                } else {
                    //Log.d("frame \(frameIndex) processing blob \(iterationBlob) @ [\(x), \(y)] FUCK 1")
                }
            } else {
                //Log.d("frame \(frameIndex) processing blob \(iterationBlob) @ [\(x), \(y)] FUCK 4")
            }
        } else {
            //Log.d("frame \(frameIndex) processing blob \(iterationBlob) @ [\(x), \(y)] FUCK 2")
        }
        return false
    }

    return true
}


