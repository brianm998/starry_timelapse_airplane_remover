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
    
    init(blobMap: [Int32: Blob],
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

    private var internalBlobMap: [Int32:Blob] = [:]
    
    public func blobMap() async -> [Int32:Blob] { internalBlobMap }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let scanSize: Int         // how far in each direction to look for neighbors
        let blobsSmallerThan: Int // ignore blobs larger than this
        let blobsLargerThan: Int  // ignore blobs smaller than this
        let lineBorder: Int       // how much furter to look at the ends of the line
        let minLineScore: Double // don't process full blobs with > average line dist
        let adjecentPixelsOnIteration: Int // how far to iterate on adject pixels
        let maxBlobsProcessed: Int         // don't process more blobs than this
        
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
            case .maxBlobsProcessed:
                return "don't process more blobs than this"
            }
        }
        
        public enum ArgType: CaseIterable, Hashable {
            case scanSize
            case blobsSmallerThan
            case blobsLargerThan
            case lineBorder
            case minLineScore
            case adjecentPixelsOnIteration
            case maxBlobsProcessed
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
            case .maxBlobsProcessed:
                return Double(maxBlobsProcessed)
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
                            maxBlobsProcessed: self.maxBlobsProcessed)
            case .adjecentPixelsOnIteration:
                return nil

            case .maxBlobsProcessed:
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
                            maxBlobsProcessed: self.maxBlobsProcessed)

            case .blobsSmallerThan:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: value,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxBlobsProcessed: self.maxBlobsProcessed)

            case .blobsLargerThan:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: value,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxBlobsProcessed: self.maxBlobsProcessed)

            case .lineBorder:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: value,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxBlobsProcessed: self.maxBlobsProcessed)

            case .minLineScore:
                return nil

            case .adjecentPixelsOnIteration:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: value,
                            maxBlobsProcessed: self.maxBlobsProcessed)

            case .maxBlobsProcessed:
                return Args(scanSize: self.scanSize,
                            blobsSmallerThan: self.blobsSmallerThan,
                            blobsLargerThan: self.blobsLargerThan,
                            lineBorder: self.lineBorder,
                            minLineScore: self.minLineScore,
                            adjecentPixelsOnIteration: self.adjecentPixelsOnIteration,
                            maxBlobsProcessed: value)
            }
        }
        
        public init(scanSize: Int = 28,
                    blobsSmallerThan: Int = 24, 
                    blobsLargerThan: Int = 0,
                    lineBorder: Int = 0,
                    minLineScore: Double = 3,
                    adjecentPixelsOnIteration: Int = 5,
                    maxBlobsProcessed: Int = 800)
        {
            self.scanSize = scanSize
            self.blobsSmallerThan = blobsSmallerThan
            self.blobsLargerThan = blobsLargerThan
            self.lineBorder = lineBorder
            self.minLineScore = minLineScore
            self.adjecentPixelsOnIteration = adjecentPixelsOnIteration
            self.maxBlobsProcessed = maxBlobsProcessed
        }
    }

    fileprivate final class Data: Sendable {
        let args: Args
        let blobMap: [Int32:Blob]
        let blobRefs: BlobRefs
        let analyzer: BlobAnalyzer
        let frameIndex: Int

        init(args: Args,
             blobMap: [Int32:Blob],
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

        Log.d("frame \(frameIndex) starting")
        internalBlobMap = await analyzer.mapOfBlobs()
        //let blobMap = await analyzer.mapOfBlobs()
        let startTime = Date().timeIntervalSince1970


        let processedBlobs = ProcessedBlobsSync()
        
        let data = LinearBlobConnector.Data(args: args,
                                            blobMap: await analyzer.mapOfBlobs(),
                                            blobRefs: await analyzer.blobRefsObj,
                                            analyzer: analyzer,
                                            frameIndex: frameIndex)

        var blobSizes: [BlobSize] = []
        for (id, blob) in internalBlobMap {
            blobSizes.append(BlobSize(id: id, size: await blob.size(), blob: blob))
        }

        var sortedBlobs = blobSizes.sorted { $0.size > $1.size }

        let originalNumber = sortedBlobs.count
        
        if sortedBlobs.count > args.maxBlobsProcessed {
            sortedBlobs = Array(sortedBlobs[0..<args.maxBlobsProcessed])
        }
        
        Log.d("frame \(frameIndex) processing \(sortedBlobs.count) blobs out of a total of \(originalNumber)")
        
        let mappings = await withTaskGroup(of: Set<BlobMapping>.self) { taskGroup in
            for sortedBlob in sortedBlobs {
                let blob = sortedBlob.blob

                if processedBlobs.contains(blob.id) { continue }
                processedBlobs.insert(blob.id)
    
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
                      await StarCore.neighborCloud(
                        of: blob,
                        blobRefs: data.blobRefs,
                        blobMap: data.blobMap,
                        scanSize: data.args.scanSize
                      )
                    
                    if neighborCloud.count != 0 { 
                        return await processBlob(
                          blob,
                          data: data,
                          neighborCloud: neighborCloud
                        )
                    } else {
                        return []
                    }
                }
            }

            var ret = Set<BlobMapping>()
            for await blobMapping in taskGroup {
                Log.d("frame \(frameIndex) ret \(ret.count) adding \(blobMapping.count) mappings")
                ret = ret.union(blobMapping) // XXX Crashed here :(
                Log.d("frame \(frameIndex) ret \(ret.count) after adding \(blobMapping.count) mappings")
            }
            Log.d("frame \(frameIndex) returning set")
            return ret
        }

        Log.d("frame \(frameIndex) Constructing blob mapper")
        
        let blobMapper = BlobMapper(mappings: mappings)

        // next produce a list of blob ids that are all part of a new combined blob
        let mappingLists = blobMapper.mappingLists


        Log.d("frame \(frameIndex) combining blobs into \(mappingLists.count) merged blobs")
        await withTaskGroup(of: Optional<Blob>.self) { taskGroup in
            for mappingList in mappingLists {
                // a list of blobs that should all be removed
                //Log.d("mappingList.list.count \(mappingList.list.count)")

                let blobList = mappingList.compactMap { internalBlobMap[$0] }

                //Log.d("blobList.count \(blobList.count)")

                // remove blob ids from the list from the blob map
                for blobId in mappingList { internalBlobMap.removeValue(forKey: blobId) }

                taskGroup.addTask {
                    return await StarCore.combine(blobList)
                }
                for await blob in taskGroup {
                    if let blob {
                        internalBlobMap[blob.id] = blob
                    }
                }
            }
        }
        
        let endTime = Date().timeIntervalSince1970
        Log.d("frame \(frameIndex) processed in \(endTime-startTime) seconds")
    }
}

fileprivate func processBlob(
  _ blob: Blob,
  data: LinearBlobConnector.Data,
  neighborCloud: Set<Blob>
) async -> Set<BlobMapping> {
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
        let mappings =
          await iterate(on: blobLine,
                        over: fullBlob,
                        frameIndex: frameIndex,
                        data: data,
                        lineBorder: data.args.lineBorder,
                        adjecentPixelsOnIteration: data.args.adjecentPixelsOnIteration)

        let endTime = Date().timeIntervalSince1970
        Log.d("frame \(frameIndex) processed blob \(blob) in \(endTime-startTime) seconds")
        
        return mappings
    }
    let endTime = Date().timeIntervalSince1970
    Log.d("frame \(frameIndex) processed blob \(blob) in \(endTime-startTime) seconds")
    return Set<BlobMapping>()
}

fileprivate func iterate(on blobLine: Line,
                         over fullBlob: Blob,
                         frameIndex: Int,
                         // how much furter to look at the ends of the line
                         data: LinearBlobConnector.Data,
                         lineBorder: Int,
                         iterationCount: Int = 0,
                         adjecentPixelsOnIteration: Int) async -> Set<BlobMapping>
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
        
    var ret = Set<BlobMapping>()
    if let start, let end {

        Log.d("frame \(frameIndex) blob \(fullBlob.id) iterating between \(start) and \(end)")
        let linearBlobIds = SetActor<Int32>()
        // iterate over the line and absorbs all blobs along it into a new blob
        // remove all ids except for the one from the combined blob ids from the blob map

        // this is the maximum distance allowed along the line between pixels
        let maxDistance: Double = 50    // XXX make a param
        
        await blobLine.asyncIterate(
          between: start,
          and: end,
          numberOfAdjecentPixels: adjecentPixelsOnIteration
        ) { (x: Int, y: Int, orientation: IterationOrientation, lastCoord: Coord?) in
            if x >= 0,
               y >= 0,
               x < data.analyzer.width,
               y < data.analyzer.height
            {
                // look for blobs at x,y, i.e. blobs that are right on the line
                let index = y*data.analyzer.width+x
                let blobId = data.blobRefs.refs[index]
                if blobId != 0 {
                    if let _lastCoord = lastCoord {
                        if _lastCoord.distanceFrom(x: x, y: y) < maxDistance {
                            await linearBlobIds.insert(blobId)
                            return Coord(x: x, y: y)
                        }
                    } else {
                        await linearBlobIds.insert(blobId)
                        return Coord(x: x, y: y)
                    }
                }
            }
            return lastCoord
        }

        var linearBlobSet = await linearBlobIds.set.compactMap { data.blobMap[$0] }
        
        if linearBlobSet.count > 1 {

            let firstBlob = linearBlobSet.removeFirst()
            
            Log.d("frame \(data.analyzer.frameIndex) blob \(fullBlob.id) found \(await linearBlobIds.count) linear blobs")
            
            // we found more than one blob along the line
            // record a mapping between them 

            for otherBlob in linearBlobSet {
                ret.insert(BlobMapping(firstBlob.id, otherBlob.id))
            }

            Log.d("frame \(data.analyzer.frameIndex) fullBlob \(fullBlob.id) after absorb \(await fullBlob.pixels.count)")
            
        } else {
            Log.d("frame \(data.analyzer.frameIndex) only found \(linearBlobSet.count) linear blobs")
        }
    }
    return ret
}
