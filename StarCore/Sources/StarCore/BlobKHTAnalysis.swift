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


// analyze the blobs with kernel hough transform data from the subtraction image
// filters the blob map, and combines nearby blobs on the same line
class BlobKHTAnalysis: AbstractBlobAnalyzer {

    var blobsToPromote: [String:Blob] = [:]
    private let maxVotes = 12000     // lines with votes over this are max color on kht image
    private let khtImageBase = 0x1F  // dimmest lines will be 

    var blobsNotPromoted: [String:Blob] = [:]
    
    init(houghLines: [MatrixElementLine],
         blobMap blobMap: [String: Blob],
         config: Config,
         width: Int,
         height: Int,
         frameIndex: Int,
         imageAccessor: ImageAccess) async throws
    {

        super.init(blobMap: blobMap,
                   config: config,
                   width: width,
                   height: height,
                   frameIndex: frameIndex,
                   imageAccessor: imageAccessor)

        var khtImage: [UInt8] = []
        if config.writeOutlierGroupFiles {
            khtImage = [UInt8](repeating: 0, count: width*height)
        }

        Log.i("frame \(frameIndex) loaded subtraction image")

        for elementLine in houghLines {
            let element = elementLine.element

            // when theta is around 300 or more, then we get a bad line here :(
            let line = elementLine.originZeroLine
            
            //Log.i("frame \(frameIndex) matrix element [\(element.x), \(element.y)] -> [\(element.width), \(element.height)] processing line theta \(line.theta) rho \(line.rho) votes \(line.votes) blobsToProcess \(blobsToProcess.count)")

            var brightnessValue: UInt8 = 0xFF

            // calculate brightness to display line on kht image
            if line.votes < maxVotes {
                brightnessValue = UInt8(Double(line.votes)/Double(maxVotes) *
                                          Double(0xFF - khtImageBase) +
                                          Double(khtImageBase))
            }

            var lastBlob = LastBlob()
            
            // XXX yet another hardcoded constant :(
            line.iterate(on: elementLine, withExtension: 256) { x, y, direction in
                if x < width,
                   y < height
                {
                    if config.writeOutlierGroupFiles {
                        // write kht image data
                        let index = y*width+x
                        if khtImage[index] < brightnessValue {
                            khtImage[index] = brightnessValue
                        }
                    }

                    // do blob processing at this location
                    processBlobsAt(x: x,
                                   y: y,
                                   on: line,
                                   iterationOrientation: direction,
                                   lastBlob: &lastBlob)
                    
                }
            }
        }

        if config.writeOutlierGroupFiles {
            // save image of kht lines
            let image = PixelatedImage(width: width, height: height,
                                       grayscale8BitImageData: khtImage)
            try await imageAccessor.save(image, as: .houghLines,
                                         atSize: .original, overwrite: true)
            try await imageAccessor.save(image, as: .houghLines,
                                         atSize: .preview, overwrite: true)
        }

        self.filteredBlobs = Array(blobsToPromote.values)

        for (blobId, blob) in blobMap {
            if blobsToPromote[blobId] == nil {
                blobsNotPromoted[blobId] = blob
            }
        }
    }

    
    // looks around for blobs close to this place
    private func processBlobsAt(x sourceX: Int,
                                y sourceY: Int,
                                on line: Line,
                                iterationOrientation: IterationOrientation,
                                lastBlob: inout LastBlob) 
    {

        //Log.d("frame \(frameIndex) processBlobsAt [\(sourceX), \(sourceY)] on line \(line) lastBlob \(lastBlob)")
                            
        // XXX calculate this differently based upon the theta of the line
        // a 45 degree line needs more extension to have the same distance covered
        var searchDistanceEachDirection = 8 // XXX constant

        var startX = sourceX
        var startY = sourceY

        var endX = sourceX+1
        var endY = sourceY+1
        
        switch iterationOrientation {
        case .vertical:
            startY -= searchDistanceEachDirection
            endY += searchDistanceEachDirection
            if startY < 0 { startY = 0 }
            
            //Log.d("frame \(frameIndex) processing vertically from \(startY) to \(endY) on line \(line) lastBlob \(lastBlob.blob)")
            
            for y in startY ..< endY {
                processBlobAt(x: sourceX, y: y,
                              on: line,
                              lastBlob: &lastBlob)
            }
            
        case .horizontal:
            startX -= searchDistanceEachDirection
            endX += searchDistanceEachDirection
            if startX < 0 { startX = 0 }
            
            //Log.d("frame \(frameIndex) processing horizontally from \(startX) to \(endX) on line \(line) lastBlob \(lastBlob.blob)")
            
            for x in startX ..< endX {
                processBlobAt(x: x, y: sourceY,
                              on: line,
                              lastBlob: &lastBlob)
            }
        }
    }

    // process a blob at this particular spot
    private func processBlobAt(x: Int, y: Int,
                               on line: Line,
                               lastBlob: inout LastBlob) 
    {
        if y < height,
           x < width,
           let blobId = blobRefs[y*width+x],
           let blob = blobMap[blobId]
        {
            // lines are invalid for this blob
            // if there is already a line on the blob and it doesn't match
            var lineIsValid = true

            var lineForNewBlobs = line
            if let blobLine = blob.line {
                lineForNewBlobs = blobLine
                lineIsValid = blobLine.thetaMatch(line, maxThetaDiff: 10) // medium, 20 was generous, and worked

//                if !lineIsValid {
                    //Log.i("frame \(frameIndex) HOLY CRAP [\(x), \(y)]  blobLine \(blobLine) from \(blob) doesn't match line \(line)")
//                }
            }

            if lineIsValid { 
                if let _lastBlob = lastBlob.blob {
                    if _lastBlob.id != blob.id  {
                        let distance = _lastBlob.boundingBox.edgeDistance(to: blob.boundingBox)
                        //Log.i("frame \(frameIndex) blob \(_lastBlob) bounding box \(_lastBlob.boundingBox) is \(distance) from blob \(blob) bounding box \(blob.boundingBox)")
                        if distance < 40 { // XXX constant XXX
                            // if they are close enough, simply combine them
                            if _lastBlob.absorb(blob) {
                                //Log.d("frame \(frameIndex)  blob \(_lastBlob) absorbing blob \(blob)")

                                // update blobRefs after blob absorbtion
                                for pixel in blob.pixels {
                                    blobRefs[pixel.y*width+pixel.x] = _lastBlob.id
                                }
                                blobMap.removeValue(forKey: blob.id)
                                blobsToPromote.removeValue(forKey: blob.id)
                            } else {
                                if _lastBlob.id != blob.id {
                                    Log.i("frame \(frameIndex) [\(x), \(y)] blob \(_lastBlob) failed to absorb blob \(blob)")
                                }
                            }
                        } else {
                            // if they are far, then overwrite the lastBlob var
                            blobsToPromote[blob.id] = blob
                            //Log.d("frame \(frameIndex) [\(x), \(y)] distance \(distance) from \(_lastBlob) is too far from blob with id \(blob) line \(lineForNewBlobs)")
                            lastBlob.blob = blob
                        }
                    }
                } else {
                    //Log.d("frame \(frameIndex) [\(x), \(y)] no last blob, blob \(blob) is now last - line \(lineForNewBlobs)")
                    blobsToPromote[blob.id] = blob
                    lastBlob.blob = blob
                }
            }
        }
    }
}
