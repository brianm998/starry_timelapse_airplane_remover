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

// recurse on finding nearby blobs to find groups of neighbors in a set
// use the KHT to try to combine some of them into a line (if we get a good enough line)
class LinearBlobConnector: AbstractBlobAnalyzer {

    public func process(scanSize: Int = 28,    // how far in each direction to look for neighbors
                        blobsSmallerThan: Int = 24, // ignore blobs larger than this
                        blobsLargerThan: Int = 0)  // ignore blobs smaller than this

    {
        var processedBlobs: Set<UInt16> = []
        iterateOverAllBlobs() { id, blob in
            if processedBlobs.contains(id) { return }
            processedBlobs.insert(id)
            
            // only deal with blobs in a certain size range
            if blob.size >= blobsSmallerThan || 
               blob.size < blobsLargerThan
            {
                return
            }

            Log.d("iterating over blob \(id)")

            // recursively find all neighbors 
            let (recursiveNeighbors, newProcessedBlobs) =
              recursiveNeighbors(of: blob,
                                 scanSize: scanSize,
                                 processedBlobs: processedBlobs)

            processedBlobs = processedBlobs.union(newProcessedBlobs)

            if recursiveNeighbors.count == 0 { return }
            
            Log.d("blob \(id) has \(recursiveNeighbors.count) neighbors")

            let frameIndex = recursiveNeighbors.first?.frameIndex ?? -1
            let id = recursiveNeighbors.first?.id ?? 0
            
            // first create a temporary blob that combines all of the nearby blobs
            let fullBlob = Blob(id: id, frameIndex: frameIndex) // values not used
            for blob in recursiveNeighbors { _ = fullBlob.absorb(blob, always: true) }

            // here we have combined all of the nearby blobs within our given scanSize
            // to eachother.  This may be enormous, if we have lots of small blobs close together.
            // Or or may be 50-80% small blobs on the same line.


            Log.d("blob \(id) fullBlob has \(fullBlob.pixels.count) pixels boundingBox \(fullBlob.boundingBox) line \(fullBlob.line)")

            
            // render a KHT on this full blob
            if let blobLine = fullBlob.originZeroLine {

                // XXX for testing, write out this big blob as json
                /*
                let blobJsonFilename = "/tmp/Blob_frame_\(frameIndex)_\(fullBlob).json"
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                
                do {
                    let jsonData = try encoder.encode(fullBlob)
                    
                    fileManager.createFile(atPath: blobJsonFilename,
                                           contents: jsonData,
                                           attributes: nil)
                } catch {
                    Log.e("\(error)")
                }
                */
                // we have an ideal origin zero line for this blob
                Log.d("blob \(id) has line \(blobLine)")

                var start: DoubleCoord?
                var end: DoubleCoord?
                
                switch blobLine.iterationOrientation {

                case .horizontal:
                    start = DoubleCoord(x: Double(fullBlob.boundingBox.min.x), y: 0)
                    end = DoubleCoord(x: Double(fullBlob.boundingBox.max.x), y: 0)
                    
                case .vertical:
                    start = DoubleCoord(x: 0, y: Double(fullBlob.boundingBox.min.y))
                    end = DoubleCoord(x: 0, y: Double(fullBlob.boundingBox.max.y))
                }

                if let start, let end {
                    Log.d("blob \(id) iterating between \(start) and \(end)")
                    var linearBlobIds = Set<UInt16>()
                    // iterate over the line and absorbs all blobs along it into a new blob
                    // remove all ids expept for the one from the combined blob ids from the blob map
                    
                    blobLine.iterate(between: start,
                                     and: end,
                                     numberOfAdjecentPixels: 5) // XXX constant
                    { x, y, orientation in
                        if x >= 0,
                           y >= 0,
                           x <= width,
                           y <= height
                        {
                            // look for blobs at x,y, i.e. blobs that are right on the line
                            let index = y*width+x
                            let blobId = blobRefs[index]
                            if blobId != 0 {
                                Log.d("blob \(id) found linear blob \(blobId) @ [\(x), \(y)]")
                                linearBlobIds.insert(blobId)
                            } else {
                                Log.d("blob \(id) nothing found @ [\(x), \(y)]")
                            }
                        }
                    }

                    if linearBlobIds.count > 1 {
                        Log.d("blob \(id) found \(linearBlobIds.count) linear blobs")
                        
                        // we found more than one blob alone the line
                        var linearBlobSet = linearBlobIds.compactMap { blobMap[$0] }

                        // the first blob in the set will absorb the others and survive
                        let firstBlob = linearBlobSet.removeFirst() 

                        // the others will get eaten and thrown away :(
                        for otherBlob in linearBlobSet {
                            _ = firstBlob.absorb(otherBlob, always: true)
                            blobMap.removeValue(forKey: otherBlob.id)
                        }
                        blobMap[firstBlob.id] = firstBlob // just in case
                    }
                }
            }
        }
    }
}

fileprivate let fileManager = FileManager.default
