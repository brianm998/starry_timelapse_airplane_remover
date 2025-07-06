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

public actor SetActor<T> where T: Hashable {
    private var internalSet: Set<T>

    init(with set: Set<T>) {
        self.internalSet = set
    }

    init() {
        self.internalSet = []
    }

    public var count: Int { internalSet.count }
    
    public func insert(_ value: T) {
        internalSet.insert(value)
    }

    public func contains(_ value: T) -> Bool {
        internalSet.contains(value)
    }

    public var set: Set<T> { internalSet }
}

public protocol Argable<Types> where Types: CaseIterable {
    associatedtype Types
    func value(for type: Types) -> Double?
    func description(for type: Types) -> String
    func isInteger(_ type: Types) -> Bool
    func isOptional(_ type: Types) -> Bool
}

// recurse on finding nearby blobs to find groups of neighbors in a set
// use the KHT to try to combine some of them into a line (if we get a good enough line)
public actor LinearBlobConnector {

    let analyzer: BlobAnalyzer
    let frameIndex: Int
    
    init(blobMap: [UInt32: Blob],
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

    public func blobMap() async -> [UInt32:Blob] {
        await analyzer.mapOfBlobs()
    }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let scanSize: Int         // how far in each direction to look for neighbors
        let blobsSmallerThan: Int // ignore blobs larger than this
        let blobsLargerThan: Int  // ignore blobs smaller than this
        let lineBorder: Int       // how much furter to look at the ends of the line
        let minLineScore: Double // don't process full blobs with > average line dist
        let adjecentPixelsOnIteration: Int // how far to iterate on adject pixels
        let maxIterationCount: Int // maximum times to iterate on line improvement

        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .scanSize:
                return "The maximum allowed distance used when constructing a neighbor cloud.  Each pixel must be scanSize or closer to its closest neighbor."
            case .blobsSmallerThan:
                return "ignore blobs larger than this"
            case .blobsLargerThan:
                return "ignore blobs smaller than this"
            case .lineBorder:
                return "how much further to look at the ends of the line"
            case .minLineScore:
                return "don't process full blobs with a line score less than this"
            case .adjecentPixelsOnIteration:
                return "how far to iterate on adject pixels"
            case .maxIterationCount:
                return "maximum times to iterate on line improvement"
            }
        }
        
        public enum ArgType: CaseIterable, Hashable {
            case scanSize
            case blobsSmallerThan
            case blobsLargerThan
            case lineBorder
            case minLineScore
            case adjecentPixelsOnIteration
            case maxIterationCount
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .minLineScore:
                return false
            default:
                return true
            }
        }
        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .scanSize:
                return Double(scanSize)
            case .blobsSmallerThan:
                return Double(blobsSmallerThan)
            case .blobsLargerThan:
                return Double(blobsLargerThan)
            case .lineBorder:
                return Double(lineBorder)
            case .minLineScore:
                return minLineScore
            case .adjecentPixelsOnIteration:
                return Double(adjecentPixelsOnIteration)
            case .maxIterationCount:
                return Double(maxIterationCount)
            }
        }

        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .scanSize:
                return nil
            case .blobsSmallerThan:
                return nil
            case .blobsLargerThan:
                return nil
            case .lineBorder:
                return nil
            case .minLineScore:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: value,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)
            case .adjecentPixelsOnIteration:
                return nil
            case .maxIterationCount:
                return nil
            }
        }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .scanSize:
                return Args(scanSize: value,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .blobsSmallerThan:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: value,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .blobsLargerThan:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: value,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .lineBorder:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: value,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: self.maxIterationCount)

            case .minLineScore:
                return nil

            case .adjecentPixelsOnIteration:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: value,
                            maxIterationCount: self.maxIterationCount)

            case .maxIterationCount:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxIterationCount: value)
            }
        }
        
        public init(scanSize: Int = 28,
                    blobsSmallerThan: Int = 24, 
                    blobsLargerThan: Int = 0,
                    lineBorder: Int = 0,
                    minLineScore: Double = 3,
                    adjecentPixelsOnIteration: Int = 5,
                    maxIterationCount: Int = 10)
        {
            self.scanSize = scanSize
            self.blobsSmallerThan = blobsSmallerThan
            self.blobsLargerThan = blobsLargerThan
            self.lineBorder = lineBorder
            self.minLineScore = minLineScore
            self.adjecentPixelsOnIteration = adjecentPixelsOnIteration
            self.maxIterationCount = maxIterationCount
        }
    }

    fileprivate final class Data: Sendable {
        let args: Args
        let blobMap: [UInt32:Blob]
        let blobRefs: BlobRefs
        let analyzer: BlobAnalyzer
        let frameIndex: Int

        init(args: Args,
             blobMap: [UInt32:Blob],
             blobRefs: BlobRefs,
             analyzer: BlobAnalyzer,
             frameIndex: Int)
        {
            self.args = args
            self.blobMap = blobMap
            self.blobRefs = blobRefs
            self.analyzer = analyzer
            self.frameIndex = frameIndex
        }
    }

    public func process(_ args: Args) async {

        let blobMap = await analyzer.mapOfBlobs()
        let startTime = Date().timeIntervalSince1970


        var processedBlobs = ProcessedBlobsSync()
        
        let data = LinearBlobConnector.Data(args: args,
                                            blobMap: await analyzer.mapOfBlobs(),
                                            blobRefs: await analyzer.blobRefsObj,
                                            analyzer: analyzer,
                                            frameIndex: frameIndex)

        var blobSizes: [BlobSize] = []
        for (id, blob) in blobMap {
            blobSizes.append(BlobSize(id: id, size: await blob.size(), blob: blob))
        }

        let sortedBlobs = blobSizes.sorted { $0.size > $1.size }

        Log.i("frame \(frameIndex) processing \(sortedBlobs.count) blobs")
        
        await withTaskGroup(of: Void.self) { taskGroup in
            for sortedBlob in sortedBlobs {
                let blob = sortedBlob.blob

                if await processedBlobs.contains(blob.id) { continue }
                await processedBlobs.insert(blob.id)
    
                // only deal with blobs in a certain size range
                let blobSize = await blob.size()
                
                if blobSize >= data.args.blobsSmallerThan || 
                   blobSize < data.args.blobsLargerThan
                {
                    continue
                }

                taskGroup.addTask {
                    // find a cloud of neighbors 
                    let neighborCloud =
                      await StarCore.neighborCloud(of: blob,
                                                   blobRefs: data.blobRefs,
                                                   blobMap: data.blobMap,
                                                   scanSize: data.args.scanSize)
                    
                    if neighborCloud.count != 0 { 
                        await processBlob(blob,
                                          data: data,
                                          neighborCloud: neighborCloud)
                    }
                }
            }
            await taskGroup.waitForAll()
        }
        let endTime = Date().timeIntervalSince1970
        Log.d("frame \(frameIndex) processed in \(endTime-startTime) seconds")
    }
}

fileprivate func processBlob(_ blob: Blob,
                             data: LinearBlobConnector.Data,
                             neighborCloud: Set<Blob>) async
{
    let startTime = Date().timeIntervalSince1970
    
    //Log.d("iterating over blob \(id)")

    // this appears to be blocking progress for some reason
    
    
    //Log.d("blob \(id) has \(neighborCloud.count) neighbors")

    let frameIndex = neighborCloud.first?.frameIndex ?? -1
    let id = neighborCloud.first?.id ?? 0
    
    // then create a temporary blob that combines all of the nearby blobs
    let fullBlob = Blob(id: id, frameIndex: frameIndex) // values not used
    for blob in neighborCloud { _ = await fullBlob.absorb(blob, always: true) }

    // here we have combined all of the nearby blobs within our given scanSize
    // to eachother.  This may be enormous, if we have lots of small blobs close together.
    // Or or may be 50-80% small blobs on the same line.


    //Log.d("blob \(id) fullBlob has \(await fullBlob.getPixels().count) pixels boundingBox \(await fullBlob.boundingBox()) line \(await fullBlob.line)")

    
    // render a KHT on this full blob
    if let blobLine = await fullBlob.originZeroLine,
       await fullBlob.linePixelScore(for: blobLine) > data.args.minLineScore
    {

        //Log.d("iterating on blob \(id)")
        // only iterate on blob lines if they are a decent fit
        
        // XXX for testing, write out this big blob as json
        /* 
           let blobJsonFilename = "/tmp/Blob_frame_\(frameIndex)_\(fullBlob).json"
           let encoder = JSONEncoder()
           encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
           
           do {
           let jsonData = try encoder.encode(fullBlob)
           
           FileManager.default.createFile(atPath: blobJsonFilename,
           contents: jsonData,
           attributes: nil)
           } catch {
           Log.e("\(error)")
           }

         */

        let midTime = Date().timeIntervalSince1970
        Log.d("frame \(frameIndex) before iterating on \(blob) in \(midTime-startTime) seconds")
        
        // first iterate on the best line for the full blob
        // maybe recurse on a better line from a smaller amount
        let numIterations =
          await iterate(on: blobLine,
                        over: fullBlob,
                        frameIndex: frameIndex,
                        data: data,
                        lineBorder: data.args.lineBorder,
                        maxIterationCount: data.args.maxIterationCount,
                        adjecentPixelsOnIteration: data.args.adjecentPixelsOnIteration)

        Log.d("frame \(frameIndex) iterated \(numIterations) times on blob \(blob)")

        // trim the blob here?
    } 
    let endTime = Date().timeIntervalSince1970
    Log.d("frame \(frameIndex) processed blob \(blob) in \(endTime-startTime) seconds")
}

fileprivate func iterate(on blobLine: Line,
                         over fullBlob: Blob,
                         frameIndex: Int,
                         // how much furter to look at the ends of the line
                         data: LinearBlobConnector.Data,
                         lineBorder: Int,
                         iterationCount: Int = 0,
                         maxIterationCount: Int,
                         adjecentPixelsOnIteration: Int) async -> Int
{
    // we have an ideal origin zero line for this blob
    Log.d("frame \(frameIndex) blob \(fullBlob.id) has line \(blobLine)")

    var start: DoubleCoord?
    var end: DoubleCoord?

    let boundingBox = await fullBlob.boundingBox()
    
    switch blobLine.iterationOrientation {
        
    case .horizontal:
        var min = boundingBox.min.x - lineBorder
        var max = boundingBox.max.x + lineBorder
        if min < 0 { min = 0 }
        if max >= data.analyzer.width { max = data.analyzer.width - 1 }
        start = DoubleCoord(x: Double(min), y: 0)
        end = DoubleCoord(x: Double(max), y: 0)
        
    case .vertical:
        var min = boundingBox.min.y - lineBorder
        var max = boundingBox.max.y + lineBorder
        if min < 0 { min = 0 }
        if max >= data.analyzer.height { max = data.analyzer.height - 1 }
        start = DoubleCoord(x: 0, y: Double(min))
        end = DoubleCoord(x: 0, y: Double(max))
    }

    if let start, let end {
        Log.d("frame \(frameIndex) blob \(fullBlob.id) iterating between \(start) and \(end)")
        let linearBlobIds = SetActor<UInt32>()
        // iterate over the line and absorbs all blobs along it into a new blob
        // remove all ids expept for the one from the combined blob ids from the blob map
        
        await blobLine.asyncIterate(between: start,
                                    and: end,
                                    numberOfAdjecentPixels: adjecentPixelsOnIteration)
        { x, y, orientation in
            if x >= 0,
               y >= 0,
               x < data.analyzer.width,
               y < data.analyzer.height
            {
                // look for blobs at x,y, i.e. blobs that are right on the line
                let index = y*data.analyzer.width+x
                let blobId = data.blobRefs.refs[index]
                await linearBlobIds.insert(blobId)
            }
        }

        let linearBlobSet = await linearBlobIds.set.compactMap { data.blobMap[$0] }
        
        if linearBlobSet.count > 1 {
            // use nextIndex(from blobMap:) here?
            // re-use data.analyzer.maxBlobId until we absorb another blob
            // and then grab its id instead, as maxBlobId is already used 
            let linearBlob = await Blob(id: data.analyzer.maxBlobId,
                                        frameIndex: data.frameIndex)

            Log.d("frame \(data.analyzer.frameIndex) blob \(fullBlob.id) found \(await linearBlobIds.count) linear blobs")
            
            // we found more than one blob along the line

            // the others will get eaten and thrown away :(
            for otherBlob in linearBlobSet {
                if await linearBlob.absorb(otherBlob, always: true) {
                    //Log.d("frame \(data.analyzer.frameIndex) removing \(otherBlob) \(await otherBlob.pixels.count) pixels \(await otherBlob.pixels)")
                    await data.analyzer.remove(blob: otherBlob)
                    if await linearBlob.id == data.analyzer.maxBlobId {
                        // reuse other blob's id to avoid overrunning UInt16.max
                        await linearBlob.update(id: otherBlob.id)
                    }
                }
            }

            await data.analyzer.update(blob: linearBlob)

            Log.d("frame \(data.analyzer.frameIndex) fullBlob \(fullBlob.id) after absorb \(await fullBlob.pixels.count)")
            
            /*
             If we have a line from this new blob, it is likely
             more accurate than the one we iterated on before.

             try recursing and iterating on this new line with some border
             to see what we might find.
             */

            if let line = await fullBlob.originZeroLine {
                if iterationCount < maxIterationCount {
                    Log.d("frame \(data.analyzer.frameIndex) ITERATING iterationCount \(iterationCount)")
                    return await iterate(on: line,
                                         over: linearBlob,
                                         frameIndex: frameIndex,
                                         data: data,
                                         lineBorder: lineBorder,
                                         iterationCount: iterationCount + 1,
                                         maxIterationCount: maxIterationCount,
                                         adjecentPixelsOnIteration: adjecentPixelsOnIteration) + 1
                } else {
                    Log.d("frame \(data.analyzer.frameIndex) NOT ITERATING iterationCount \(iterationCount)")
                }
            }
        } else {
            Log.d("frame \(data.analyzer.frameIndex) only found \(linearBlobSet.count) linear blobs")
        }
    }
    return 1
}
