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

// keep one of these inside each Task in the TaskGroup
public class BlobMapper {
    public var mappings: Set<BlobMapping>

    public init() {
        self.mappings = Set<BlobMapping>()
    }

    public init(mappings: Set<BlobMapping>) {
        self.mappings = mappings
    }

    // outputs a list of lists of adjecent blobs
    public var mappingLists: [[UInt32]] {
        // 1) Build an adjacency list
        var graph = [UInt32: Set<UInt32>]()
        for m in mappings {
            graph[m.id1, default: []].insert(m.id2)
            graph[m.id2, default: []].insert(m.id1)
        }

        // 2) Track which nodes we’ve already visited
        var visited = Set<UInt32>()
        var groups: [[UInt32]] = []

        // 3) For each node, if not visited, BFS/DFS to collect its component
        for node in graph.keys {
            guard !visited.contains(node) else { continue }
            var stack = [node]
            var component = [UInt32]()

            visited.insert(node)
            while let current = stack.popLast() {
                component.append(current)
                for neighbor in graph[current]! {
                    if !visited.contains(neighbor) {
                        visited.insert(neighbor)
                        stack.append(neighbor)
                    }
                }
            }

            // Optionally sort each component for determinism
            groups.append(component.sorted())
        }

        return groups
    }
    
    public static func + (lhs: BlobMapper, rhs: BlobMapper) -> BlobMapper {
        BlobMapper(mappings: lhs.mappings.union(rhs.mappings)) 
    }
}

// indicates that two blobs are linked, i.e. mapped together
public struct BlobMapping: Hashable, Equatable, Sendable {
    let id1: UInt32
    let id2: UInt32

    public init(_ id1: UInt32, _ id2: UInt32) {
        // make sure the ids are ordered so (2,1) == (1,2)
        if id1 < id2 {
            self.id1 = id1
            self.id2 = id2
        } else {
            self.id1 = id2
            self.id2 = id1
        }
    }
    
    public func contains(id: UInt32) -> Bool { id1 == id || id2 == id }
    
    public static func == (lhs: BlobMapping, rhs: BlobMapping) -> Bool {
        // [a,b] == [a,b]
        if lhs.id1 == rhs.id1,
           lhs.id2 == rhs.id2
        {
            return true
        }
        return false
    }
}

public actor OptionalActor<T> {
    private var internalValue: T? = nil

    public init(_ value: T? = nil) { internalValue = value }
    
    public var value: T? { internalValue }

    public func set(_ value: T?) { internalValue = value }
}

// attempts to combine blobs which are along detected lines by:
// 
// partitioning the full blob map image into a number of smaller slightly overlapping segments
// then iterating over lines in order of score, keeping track of what blobs are detected.
// within some pixel radius of each line, then combines blobs that are 'close enough'
//
// First a list of matching blobs from each segment is determined for each segment parallel
// Then the full list of matching blobs is condensed into groups of matching blobs
// Last these matching blobs are condensed into single blobs
public actor HoughLineMatrixBlobConnector {

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

    private var internalBlobMap: [UInt32:Blob] = [:]
    
    public func blobMap() async -> [UInt32:Blob] { internalBlobMap }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        let elementWidth: Int  // size in pixels of the width of each matrix element
        let elementHeight: Int // size in pixels of the height of each matrix element
        let overlapPercent: Double // percent that each element overlaps its neighbors
        let maxHoughLines: Int     // max number of hough lines to iterate over
        let sideIterationPixels: Int // pixel radius on line iteration
        let maxBlobDistance: Double // max blob distance on line before being connected
        
        public typealias Types = ArgType
        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .elementWidth:
                return "size in pixels of the width of each matrix element"
            case .elementHeight:
                return "size in pixels of the height of each matrix element"
            case .overlapPercent:
                return "percent that each element overlaps its neighbors"
            case .maxHoughLines:
                return "max number of hough lines to iterate over"
            case .sideIterationPixels:
                return "pixel radius on line iteration"
            case .maxBlobDistance:
                return "max blob distance on line before being connected"
            }
        }
        
        public enum ArgType: CaseIterable, Hashable {
            case elementWidth
            case elementHeight
            case overlapPercent
            case maxHoughLines
            case sideIterationPixels
            case maxBlobDistance
        }
        
        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .overlapPercent:
                return false
            case .maxBlobDistance:
                return false
            default:
                return true
            }
        }
        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .elementWidth:
                return Double(elementWidth)
            case .elementHeight:
                return Double(elementHeight)
            case .overlapPercent:
                return overlapPercent
            case .maxHoughLines:
                return Double(maxHoughLines)
            case .sideIterationPixels:
                return Double(sideIterationPixels)
            case .maxBlobDistance:
                return maxBlobDistance
            }
        }
        
        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .overlapPercent:
                return Args(elementWidth: self.elementWidth,
                            elementHeight: self.elementHeight,
                            overlapPercent: value,
                            maxHoughLines: self.maxHoughLines,
                            sideIterationPixels: self.sideIterationPixels,
                            maxBlobDistance: self.maxBlobDistance)

            case .maxBlobDistance:
                return Args(elementWidth: self.elementWidth,
                            elementHeight: self.elementHeight,
                            overlapPercent: self.overlapPercent,
                            maxHoughLines: self.maxHoughLines,
                            sideIterationPixels: self.sideIterationPixels,
                            maxBlobDistance: value)
                
            default:
                return nil
            }
        }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .elementWidth:
                return Args(elementWidth: value,
                            elementHeight: self.elementHeight,
                            overlapPercent: self.overlapPercent,
                            maxHoughLines: self.maxHoughLines,
                            sideIterationPixels: self.sideIterationPixels,
                            maxBlobDistance: self.maxBlobDistance)
            case .elementHeight:
                return Args(elementWidth: self.elementWidth,
                            elementHeight: value,
                            overlapPercent: self.overlapPercent,
                            maxHoughLines: self.maxHoughLines,
                            sideIterationPixels: self.sideIterationPixels,
                            maxBlobDistance: self.maxBlobDistance)
            case .overlapPercent:
                return nil
            case .maxHoughLines:
                return Args(elementWidth: self.elementWidth,
                            elementHeight: self.elementHeight,
                            overlapPercent: self.overlapPercent,
                            maxHoughLines: value,
                            sideIterationPixels: self.sideIterationPixels,
                            maxBlobDistance: self.maxBlobDistance)
            case .sideIterationPixels:
                return Args(elementWidth: self.elementWidth,
                            elementHeight: self.elementHeight,
                            overlapPercent: self.overlapPercent,
                            maxHoughLines: self.maxHoughLines,
                            sideIterationPixels: value,
                            maxBlobDistance: self.maxBlobDistance)
            case .maxBlobDistance:
                return nil
            }
        }

        public init(elementWidth: Int,
                    elementHeight: Int,
                    overlapPercent: Double,
                    maxHoughLines: Int,
                    sideIterationPixels: Int,
                    maxBlobDistance: Double)
        {
            self.elementWidth = elementWidth
            self.elementHeight = elementHeight
            self.overlapPercent = overlapPercent
            self.maxHoughLines = maxHoughLines
            self.sideIterationPixels = sideIterationPixels
            self.maxBlobDistance = maxBlobDistance
        }
    }

    public func process(_ args: Args) async {

        //let startTime = Date().timeIntervalSince1970
        
        // first, assemble matrix from the blobrefs in the analyzer
        let fullFrameImage = await analyzer.pixelatedImage

        //let t1 = Date().timeIntervalSince1970

        // a matrix of images from the original image for this frame
        let matrix = fullFrameImage.splitIntoMatrix(maxWidth: args.elementWidth,
                                                    maxHeight: args.elementHeight,
                                                    overlapPercent: args.overlapPercent)

        let blobImage = await analyzer.pixelatedImage

        // a matrix of images from in image that keeps track of each blob's pixels
        // used to find blobs independently for each element
        let blobMatrix = blobImage.splitIntoMatrix(maxWidth: args.elementWidth,
                                                   maxHeight: args.elementHeight,
                                                   overlapPercent: args.overlapPercent)
        
        
        //let t2 = Date().timeIntervalSince1970

        // start with the full list of blobs from the analyzer
        internalBlobMap = await analyzer.mapOfBlobs()
        Log.d("frame \(frameIndex) starting with \(internalBlobMap.count) blobs")

        let initialBlobCount = internalBlobMap.count
        
        // determine what blobs can be combined
        let mappings = await withTaskGroup(of: Set<BlobMapping>.self) { taskGroup in
            // for each matrix element:
            for (index, element) in matrix.enumerated() {
                let blobElement = blobMatrix[index]
                taskGroup.addTask { [self] in
                    let ret = await StarCore.process(element: element,
                                                     blobElement: blobElement,
                                                     with: args,
                                                     frameIndex: frameIndex,
                                                     blobMap: internalBlobMap)
                    Log.d("frame \(frameIndex) element \(index) is done")
                    return ret
                }
            }
            var ret = Set<BlobMapping>()
            for await blobMapping in taskGroup {
                Log.d("ret \(ret.count) adding \(blobMapping.count) mappings")
                ret = ret.union(blobMapping) // XXX Crashed here :(
                Log.d("ret \(ret.count) after adding \(blobMapping.count) mappings")
            }
            Log.d("returning set")
            return ret
        }
        Log.d("frame \(frameIndex) done calculating lines got \(mappings.count) mappings")

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

                taskGroup.addTask { [self] in
                    return await StarCore.combine(blobList)
                }
                for await blob in taskGroup {
                    if let blob {
                        internalBlobMap[blob.id] = blob
                    }
                }
            }
        }
        let finalBlobCount = internalBlobMap.count
        Log.d("frame \(frameIndex) done with \(internalBlobMap.count) blobs \(initialBlobCount-finalBlobCount) difference")
    }
}

fileprivate func combine(_ blobList: [Blob]) async -> Blob? {
    if blobList.count == 0 { return nil }
    let first = blobList[0]
    for i in 1..<blobList.count {
        await first.absorb(blobList[i])
    }
    return first
}

fileprivate func process(element: ImageMatrixElement,
                         blobElement: ImageMatrixElement,
                         with args: HoughLineMatrixBlobConnector.Args,
                         frameIndex: Int,
                         blobMap: [UInt32: Blob]) async -> Set<BlobMapping>
{ 
    //let elementStartTime = Date().timeIntervalSince1970
    let processedBlobs = SetActor<Blob>()

    let finderArgs = HoughLineFinder.Args(imageDataBorderSize: 0,                                         
                                          maxLineConstant: args.maxHoughLines)
    
    // find lines
    let finder = /*Combined*/HoughLineFinder(pixels: element.sortablePixels,
                                             bounds: element.bounds,
                                             args: finderArgs,
                                             frameIndex: frameIndex)

    //let houghLinesTime = Date().timeIntervalSince1970

    var lines = finder.lineData
    lines.sort { $0.score > $1.score }

    if lines.count > args.maxHoughLines {
        lines = Array(lines[0..<args.maxHoughLines])
    }

    let ret = SetActor<BlobMapping>()
    
    // iterate over lines in order of score
    for line in lines {

        //let lineStartTime = Date().timeIntervalSince1970

        let lastSeenBlob = OptionalActor<Blob>()
        let lastSeenX = OptionalActor<Int>()
        let lastSeenY = OptionalActor<Int>()
        
        let originZeroLine = finder.originZeroLine(from: line.line)

        // find intersections of this line with this matrix element
        let intersections = element.bounds.intersections(with: originZeroLine.standardLine)

        // if we have more than one itersection, iterate through them
        if intersections.count > 1 {

            // iterate through blob data on each line
            await originZeroLine.asyncIterate(between: intersections[0],
                                              and: intersections[1],
                                              numberOfAdjecentPixels: args.sideIterationPixels)
            { x, y, direction in
                if let potentialBlobId = blobElement.intensity(atX: x, andY: y),
                   potentialBlobId < UInt32.max,
                   let blob = blobMap[UInt32(potentialBlobId)]
                {
                    if let lastSeenBlob = await lastSeenBlob.value,
                       lastSeenBlob == blob
                    {
                        await lastSeenX.set(x)
                        await lastSeenY.set(y)
                    }
                    
                    // skip already seen blobs on this element iteration
                    if await !processedBlobs.contains(blob) { 

                        // for each blob encountered, keep track of it
                        await processedBlobs.insert(blob)
                        
                        if let previousBlob = await lastSeenBlob.value,
                           let lastSeenX = await lastSeenX.value,
                           let lastSeenY = await lastSeenY.value
                        {
                            let distance = distance(x, y, lastSeenX, lastSeenY)
                            //  when another blob is encountered,
                            // see how far along the line we've gotten since the last one
                            if distance < args.maxBlobDistance {
                                // if close enough, combine the blobs

                                /*

                                 may help to check to see if the blobs lines are aligned
                                 if not, then maybe don't combine them here,
                                 and maybe don't mark this blob as having been seen on this
                                 element iteration
                                 
                                 */

                                // make a new mapping here
                                await ret.insert(BlobMapping(blob.id, previousBlob.id))

                            } else {
                                // if too far, discard previous blob ref and keep track of new blob
                                await lastSeenBlob.set(blob)
                            }
                        } else {
                            // no previous last seen blob, set it to this blob
                            await lastSeenBlob.set(blob)
                        }
                        await lastSeenX.set(x)
                        await lastSeenY.set(y)
                    }
                }
            }
        }
        //let lineEndTime = Date().timeIntervalSince1970
        //Log.d("frame \(frameIndex) times line finished in \(lineEndTime-lineStartTime)")
    }

    return await ret.set
}

func distance(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Double {
    let x_diff = abs(x1-x2)
    let y_diff = abs(y1-y2)
    return sqrt(Double(x_diff*x_diff)+Double(y_diff*y_diff))
}
