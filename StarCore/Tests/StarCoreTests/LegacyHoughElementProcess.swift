import Foundation
@testable import StarCore

// The matrix connector's per-element walk as it was before S11 (actors for every step),
// kept as the reference the synchronous version is compared against.

func legacyProcess(element: ImageMatrixElement,
                         blobElement: ImageMatrixElement,
                         with args: HoughLineMatrixBlobConnector.Args,
                         frameIndex: Int,
                         blobMap: [Int32: Blob]) async -> Set<BlobMapping>
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
    lines.sort { $0.intensityScore > $1.intensityScore }

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
                   potentialBlobId < Int32.max,
                   let blob = blobMap[Int32(potentialBlobId)]
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


