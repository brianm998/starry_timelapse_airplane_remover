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

// this class takes a map of blobs and digests them by absorbing ones which
// form good lines together
public class BlobAbsorber {

    // a reference for each pixel for each blob it might belong to
    private var blobRefs: [String?]

    private var blobsProcessed: [String: Bool] = [:] // keyed by blob id, true if processed

    private let mask: CircularMask
    private let circularIterator: CircularIterator
    
    private var blobMap: [String: Blob]
    private var blobs: [Blob]

    private var lastX: Int = 0
    private var lastY: Int = 0

    private var iterationCount = 0
    
    // row major indexed array used for keeping track of checked pixels
    private var pixelProcessing: [String?]

    private var blobToAdd: Blob
    
    var filteredBlobs: [Blob] = []
    
    let frameIndex: Int
    let frameWidth: Int
    let frameHeight: Int

    // XXX constants
    
    // how many pixels do we search away from the line for other blobs
    let circularMaskRadius: Int = 14

    // radius used when searching without a line
    let circularIterationRadus = 18

    // how far away from the last blob pixel do we iterate on a line
    let maxLineIterationDistance: Double = 30

    // blobs smaller than this aren't processed directly, though they
    // may be absorbed by larger nearby blobs
    // processing all of the blobs like this take a really long time, this is a cutoff
    let minBlobProcessingSize = 160
    //let minBlobProcessingSize = 320

    // how var away from a line do we look for members of a group?
    let maxLineDist = 2
    
    init(blobMap: [String: Blob],
         frameIndex: Int,
         frameWidth: Int,
         frameHeight: Int)
    {
        self.frameIndex = frameIndex
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.blobMap = blobMap
        self.blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")

        // sort by size, biggest first
        blobs.sort { $0.size > $1.size }
        
        self.blobRefs = [String?](repeating: nil, count: frameWidth*frameHeight)

        self.blobToAdd = Blob(frameIndex: frameIndex)
        
        for blob in blobMap.values {
            for pixel in blob.pixels {
                blobRefs[pixel.y*frameWidth+pixel.x] = blob.id
            }
        }

        // used for blobs with lines, convolved across line
        self.mask = CircularMask(radius: circularMaskRadius)

        // used for blobs without lines, starts at center of blob
        self.circularIterator = CircularIterator(radius: circularIterationRadus)
        
        // row major indexed array used for keeping track of checked pixels for this blob
        self.pixelProcessing = [String?](repeating: nil, count: frameWidth*frameHeight)

        for (index, blob) in blobs.enumerated() {

            if let blobProcessed = blobsProcessed[blob.id],
               blobProcessed
            {
                continue
            }
            
            if blob.size < minBlobProcessingSize {
                // don't process them, but don't discard all of them either
                filteredBlobs.append(blob)
                continue
            }

            for i in 0..<pixelProcessing.count { pixelProcessing[i] = nil }
            
            self.blobToAdd = blob
            blobsProcessed[blob.id] = true

            let startTime = NSDate().timeIntervalSince1970

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

                self.lastX = Int(centralLineCoord.x)
                self.lastY = Int(centralLineCoord.y)
                
                Log.d("frame \(frameIndex) blob index \(index) line filtering blob \(blob) lastX \(lastX) lastY \(lastY)")

                iterationCount = 0

                blobLine.iterate(.forwards, from: centralLineCoord) { x, y, _ in
                    self.blobLineIterate(x, y)
                }

                Log.d("frame \(frameIndex) blob index \(index) iterated fowards \(iterationCount) times")

                self.lastX = Int(centralLineCoord.x)
                self.lastY = Int(centralLineCoord.y)
                
                iterationCount = 0
                
                blobLine.iterate(.backwards, from: centralLineCoord) { x, y, _ in
                    self.blobLineIterate(x, y)
                }
                Log.d("frame \(frameIndex) blob index \(index) iterated backwards \(iterationCount) times")
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
                       x < frameWidth,
                       y < frameHeight
                    {
                        let frameIndex = y*frameWidth+x

                        // see if there is another blob at this frame index that
                        // we can use to form a line
                        if process(frameIndex: frameIndex) {
                            // this blob and another were just combined and have a line
                            // need to switch to the line iteration
                            // and break out of this iteration loop.

                            Log.d("frame \(frameIndex) blob index \(index) blobToAdd \(blobToAdd) just absorbed another blob")
                            
                            didAbsorb = true
                            return false
                        }
                    }
                    return true
                }
                if didAbsorb,
                   let blobLine = blobToAdd.originZeroLine,
                   let centralLineCoord = blobToAdd.originZeroCentralLineCoord
                {
                    Log.d("frame \(frameIndex) absorbed non-line blob into line \(blobLine) and now line iterating")
                    // here we found a blob that had no line and combined it with another
                    // and now there is a line.
                    // iterate across that line

                    self.lastX = Int(centralLineCoord.x)
                    self.lastY = Int(centralLineCoord.y)
                    
                    iterationCount = 0
                
                    blobLine.iterate(.forwards, from: centralLineCoord) { x, y, _ in
                        self.blobLineIterate(x, y)
                    }

                    self.lastX = Int(centralLineCoord.x)
                    self.lastY = Int(centralLineCoord.y)

                    iterationCount = 0
                    
                    blobLine.iterate(.backwards, from: centralLineCoord) { x, y, _ in
                        self.blobLineIterate(x, y)
                    }
                }
            }

            let endTime = NSDate().timeIntervalSince1970
            Log.d("frame \(frameIndex) adding filtered blob \(blobToAdd) after \(endTime-startTime) seconds of processing")
            filteredBlobs.append(blobToAdd)

            // reset the blobToAdd to be empty after adding filtered blob
            self.blobToAdd = Blob(frameIndex: frameIndex)
        }
    }

    // iterate across the circular mask centered at x/y
    private func blobLineIterate(_ x: Int, _ y: Int) -> Bool {

        iterationCount += 1
        
        let xStart = x - mask.radius
        let yStart = y - mask.radius

        let xEnd = x + mask.radius + 1
        let yEnd = y + mask.radius + 1

        // all of these cases are completely outside the frame
        /*
        if xStart > frameWidth { return false }
        if yStart > frameHeight { return false }
        if xEnd < 0 { return false }
        if yEnd < 0 { return false }
        */
        mask.iterate { blobX, blobY in
            let frameX = xStart + blobX
            let frameY = yStart + blobY
            
            if frameX >= 0,
               frameY >= 0,
               frameX < frameWidth,
               frameY < frameHeight
            {
                process(frameIndex: frameY*frameWidth+frameX)

                // check to see if this x/y is close to
                // blobToAdd, and use that to see how far away from
                // that blob we have become.

                for checkX in frameX-maxLineDist..<frameX+maxLineDist {
                    for checkY in frameY-maxLineDist..<frameY+maxLineDist {
                        if checkX >= 0,
                           checkY >= 0,
                           checkX < frameWidth,
                           checkY < frameHeight,
                           let blobId = blobRefs[checkY*frameWidth+checkX],
                           blobId == blobToAdd.id
                        {
                            lastX = checkX
                            lastY = checkY
                        }
                    }
                }
            }
        }

        // use lastX/lastY to see how far away we are from the last know part of blobToAdd
        let xDiff = Double(x - lastX)
        let yDiff = Double(y - lastY)
        let distance = sqrt(xDiff*xDiff + yDiff*yDiff)

        if distance < maxLineIterationDistance {
            // continue if iterating on this line if distance is low enough
            return true
        }

        Log.d("frame \(frameIndex) after \(iterationCount) iterations blob \(blobToAdd) at [\(x), \(y)] has distance \(distance) from [\(lastX), \(lastY)]")
        
        return false
    }
    

    // see if we can absorb another blob from the given frame index that makes
    // the blobToAdd a better line
    private func process(frameIndex: Int) -> Bool {
        
        if let processingBlob = pixelProcessing[frameIndex],
           processingBlob == blobToAdd.id
        {
            // this blob has already processed this pixel
            return false
        }
        pixelProcessing[frameIndex] = blobToAdd.id

        // is there a different blob at this x,y?
        if let blobId = blobRefs[frameIndex],
           blobId != blobToAdd.id
        {
            if let blobProcessed = blobsProcessed[blobId],
               blobProcessed
            {
                // we've already processed this blob
                return false
            }
            if let innerBlob = blobMap[blobId],
               let absorbedBlob = blobToAdd.lineMerge(with: innerBlob)
            {
                Log.d("frame \(frameIndex) blobToAdd \(blobToAdd) absorbed \(innerBlob) to become \(absorbedBlob)")
                // use this new blob as it is better combined than separate
                self.blobToAdd = absorbedBlob
                // ignore the index of the absorbed blob in the future
                blobsProcessed[innerBlob.id] = true

                for pixel in innerBlob.pixels {
                    blobRefs[pixel.y*frameWidth+pixel.x] = absorbedBlob.id
                }
                
                return true
            }
        }
        return false
    }
}


