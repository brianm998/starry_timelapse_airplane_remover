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


// a rewrite of the BlobAbsorber that users the AbstractBlobAnalyzer superclass
class BlobAbsorberRewrite: AbstractBlobAnalyzer {

    // radius used when searching without a line
    let circularIterationRadus = 18

    private let circularIterator: CircularIterator

    private var blobsProcessed: [String: Bool] = [:] // keyed by blob id, true if processed

    override init(blobMap: [String: Blob],
                  config: Config,
                  width: Int,
                  height: Int,
                  frameIndex: Int,
                  imageAccessor: ImageAccess)
    {
        // used for blobs without lines, starts at center of blob
        self.circularIterator = CircularIterator(radius: circularIterationRadus)
        
        super.init(blobMap: blobMap,
                   config: config,
                   width: width,
                   height: height,
                   frameIndex: frameIndex,
                   imageAccessor: imageAccessor)
    }

    public func process() {
        iterateOverAllBlobs() { index, blob in 

            if let blobProcessed = blobsProcessed[blob.id],
               blobProcessed
            {
                return
            }
            
            var lastBlob = LastBlob()
            lastBlob.blob = blob

            blobsProcessed[blob.id] = true

            Log.d("frame \(frameIndex) processing blob \(blob)")

            // XXX this is a guess, that doesn't take into account the line's orientation
            var maxDistanceForThisBlob = Double(blob.boundingBox.width + blob.boundingBox.height)
            if maxDistanceForThisBlob < 100 { maxDistanceForThisBlob = 100 } // XXX constant XXX

            if let blobLine = blob.originZeroLine,
               let centralLineCoord = blob.originZeroCentralLineCoord
            {
                // search along the line, convolving a small search area across it
                // search first one direction from the blob center,
                // then search the other direction from the blob center, to attach
                // closer blob first

                // iterate from central cooord on it
                // in both positive and negative directions
                // stop when we go too far or out of frame,
                // or too far from last blob point on the line

                Log.d("frame \(frameIndex) iterating along \(blobLine) from \(centralLineCoord)")

                var iterationCount = 0
                
                blobLine.iterate(.forwards, from: centralLineCoord) { x, y, direction in
                    //Log.d("frame \(frameIndex) iterate [\(x), \(y)]")
                    iterationCount += 1
                    if x >= 0,
                       y >= 0,
                       x < width,
                       y < height
                    {
                        processBlobsAt(x: x,
                                       y: y,
                                       on: blobLine,
                                       iterationOrientation: direction,
                                       lastBlob: &lastBlob)
                    }
                    return shouldContinue(from: centralLineCoord,
                                          x: x, y: y,
                                          max: maxDistanceForThisBlob)
                }

                Log.d("frame \(frameIndex) iterated forwards \(iterationCount) times")
                
                blobLine.iterate(.backwards, from: centralLineCoord) { x, y, direction in
                    if x >= 0,
                       y >= 0,
                       x < width,
                       y < height
                    {
                        processBlobsAt(x: x,
                                       y: y,
                                       on: blobLine,
                                       iterationOrientation: direction,
                                       lastBlob: &lastBlob)
                    }
                    return shouldContinue(from: centralLineCoord,
                                          x: x, y: y,
                                          max: maxDistanceForThisBlob)
                }
            } else {
                Log.d("frame \(frameIndex) blob index \(index) circularly filtering blob \(blob)")
                // search radially, in an ever expanding circle from the center point,
                // processing closer blobs first

                // create pixel mask like CenterMask, but allow sorting of pixels by distance
                // from center.
         
                var didAbsorb = false
                
                let blobCenter = blob.boundingBox.center

                // iterate out from the center
                circularIterator.iterate(x: blobCenter.x, y: blobCenter.y) { x, y in
                    if x >= 0,
                       y >= 0,
                       x < width,
                       y < height
                    {
                        let frameIndex = y*width+x

                        // see if there is another blob at this frame index that
                        // we can use to form a line
                        if process(frameIndex: frameIndex, lastBlob: &lastBlob) {
                            // this blob and another were just combined and have a line
                            // need to switch to the line iteration
                            // and break out of this iteration loop.

                            Log.d("frame \(frameIndex) blob index \(index) blob \(blob) just absorbed another blob")
                            
                            didAbsorb = true
                            return false
                        }
                    }
                    return true
                }
                if didAbsorb,
                   let blobLine = blob.originZeroLine,
                   let centralLineCoord = blob.originZeroCentralLineCoord
                {
                    Log.d("frame \(frameIndex) absorbed non-line blob into line \(blobLine) and now line iterating")
                    // here we found a blob that had no line and combined it with another
                    // and now there is a line.
                    // iterate across that line

                
                    blobLine.iterate(.forwards, from: centralLineCoord) { x, y, direction in
                        processBlobsAt(x: x,
                                       y: y,
                                       on: blobLine,
                                       iterationOrientation: direction,
                                       lastBlob: &lastBlob)
                        return shouldContinue(from: centralLineCoord,
                                              x: x, y: y,
                                              max: maxDistanceForThisBlob)
                    }

                    blobLine.iterate(.backwards, from: centralLineCoord) { x, y, direction in
                        processBlobsAt(x: x,
                                       y: y,
                                       on: blobLine,
                                       iterationOrientation: direction,
                                       lastBlob: &lastBlob)
                        return shouldContinue(from: centralLineCoord,
                                              x: x, y: y,
                                              max: maxDistanceForThisBlob)
                    }
                }
            }
        }
    }


    // see if we can absorb another blob from the given frame index that makes
    // the blobToAdd a better line
    private func process(frameIndex: Int,
                         lastBlob lastBlobParam: inout LastBlob) -> Bool {
        
        // is there a different blob at this x,y?
        if let blobId = blobRefs[frameIndex],
           let lastBlob = lastBlobParam.blob,
           blobId != lastBlob.id
        {
            if let blobProcessed = blobsProcessed[blobId],
               blobProcessed
            {
                // we've already processed this blob
                return false
            }
            if let innerBlob = blobMap[blobId],
               let absorbedBlob = lastBlob.lineMerge(with: innerBlob)
            {
                Log.d("frame \(frameIndex) lastBlob \(lastBlob) absorbed \(innerBlob) to become \(absorbedBlob)")
                // use this new blob as it is better combined than separate
                lastBlobParam.blob = absorbedBlob
                
                // ignore the index of the absorbed blob in the future
                blobsProcessed[innerBlob.id] = true

                for pixel in innerBlob.pixels {
                    blobRefs[pixel.y*width+pixel.x] = absorbedBlob.id
                }
                
                return true
            }
        }
        return false
    }
    
    private func shouldContinue(from origin: DoubleCoord,
                                x: Int, y: Int, max: Double) -> Bool
    {
        let x_diff = origin.x - Double(x)
        let y_diff = origin.y - Double(y)
        return sqrt(x_diff*x_diff + y_diff*y_diff) < max
    }
}
