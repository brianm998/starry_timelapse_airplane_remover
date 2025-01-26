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

public actor OptionalActor<T> {
    private var internalValue: T? = nil

    public init(_ value: T? = nil) { internalValue = value }
    
    public var value: T? { internalValue }

    public func set(_ value: T?) { internalValue = value }
}

// partitions the full blob map image into a number of segments
// then iterates over lines in order of score,
// keeping track of what blobs are detected
// within some pixel radius of each line
// then combines blobs that are 'close enough'
public actor HoughLineMatrixBlobConnector {

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

        let startTime = Date().timeIntervalSince1970
        
        // first, assemble matrix from the blobrefs in the analyzer
        let fullFrameImage = await analyzer.pixelatedImage

        let t1 = Date().timeIntervalSince1970
        
        let matrix = fullFrameImage.splitIntoMatrix(maxWidth: args.elementWidth,
                                                    maxHeight: args.elementHeight,
                                                    overlapPercent: args.overlapPercent)

        let blobImage = await analyzer.pixelatedImage

        // used to find blobs independently for each element
        let blobMatrix = blobImage.splitIntoMatrix(maxWidth: args.elementWidth,
                                                   maxHeight: args.elementHeight,
                                                   overlapPercent: args.overlapPercent)
        
        
        let t2 = Date().timeIntervalSince1970

        await withTaskGroup(of: Void.self) { taskGroup in
            // for each matrix element:
            for (index, element) in matrix.enumerated() {
                let blobElement = blobMatrix[index]
                taskGroup.addTask { [self] in
                    await StarCore.process(element: element,
                                           blobElement: blobElement,
                                           with: args,
                                           frameIndex: frameIndex,
                                           analyzer: analyzer)
                }
            }
        }
    }
}

fileprivate func process(element: ImageMatrixElement,
                         blobElement: ImageMatrixElement,
                         with args: HoughLineMatrixBlobConnector.Args,
                         frameIndex: Int,
                         analyzer: BlobAnalyzer) async
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

    let blobMap = await analyzer.mapOfBlobs()
    
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
                   potentialBlobId < UInt16.max,
                   let blob = blobMap[UInt16(potentialBlobId)]
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
                                
                                if await previousBlob.absorb(blob, always: true) {
                                    await analyzer.replace(blob: blob, with: previousBlob)
                                }
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
}

func distance(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int) -> Double {
    let x_diff = abs(x1-x2)
    let y_diff = abs(y1-y2)
    return sqrt(Double(x_diff*x_diff)+Double(y_diff*y_diff))
}
