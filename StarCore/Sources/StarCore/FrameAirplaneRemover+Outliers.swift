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


class LastBlob {
    var blob: Blob?
}

/*

 Logic that loads, and finds outliers in a frame.
 
 */
extension FrameAirplaneRemover {

    public func loadOutliers() async throws {
        if self.outlierGroups == nil {
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = await outlierGroupLoader() {
                for outlier in outlierGroups.members.values {
                    outlier.setFrame(self) 
                }
                                                                  
                self.outlierGroups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                self.state = .readyForInterFrameProcessing
                self.outliersLoadedFromFile = true
                Log.i("loaded \(String(describing: self.outlierGroups?.members.count)) outlier groups for frame \(frameIndex)")
            } else {
                self.outlierGroups = OutlierGroups(frameIndex: frameIndex,
                                                   members: [:])

                Log.i("calculating outlier groups for frame \(frameIndex)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await self.findOutliers()

                // perhaps apply validation image to outliers here if possible
            }
        }
    }
    
    func findOutliers() async throws {

        Log.d("frame \(frameIndex) finding outliers")

        // contains the difference in brightness between the frame being processed
        // and its aligned neighbor frame.  Indexed by y * width + x
        var subtractionArray: [UInt16] = []
        var subtractionImage: PixelatedImage?
        self.state = .loadingImages
        do {
            // try to load the image subtraction from a pre-processed file

            if let image = await imageAccessor.load(type: .subtracted, atSize: .original) {
                subtractionImage = image
                switch image.imageData {
                case .sixteenBit(let array):
                    subtractionArray = array
                case .eightBit(_):
                    Log.e("eight bit images not supported here yet")
                }
                Log.d("frame \(frameIndex) loaded outlier amounts from subtraction image")

                try await imageAccessor.save(image, as: .subtracted,
                                             atSize: .preview, overwrite: false)
            }
        } catch {
            Log.i("frame \(frameIndex) couldn't load outlier amounts from subtraction image")
            // do the image subtraction here instead
        }
        if subtractionImage == nil {        
            let image = try await self.subtractAlignedImageFromFrame()
            subtractionImage = image
            switch image.imageData {
            case .eightBit(_):
                fatalError("NOT SUPPORTED YET")
            case .sixteenBit(let origImagePixels):
                subtractionArray = origImagePixels
            }
            Log.d("loaded subtractionArray with \(subtractionArray.count) items")
        }
        /*

         New outlier detection logic:

         * do pretty radical initial full frame blob detection, get lots of small dim blobs
         * originally sort blobs by size, processing largest first
         - if a blob can have a line detected from it,
           search along the line by convolving a search area across it to find pixels
           extend some amount past the known blob area on each side of the line
         - if a blob has no line, search in a larger circular area centered on the blob
         - each other nearby blob found is then subject to line analysis,
           and if a fit, is absorbed into the original blob.
           This can then expand the search area.
         - after all possible line connections are made, 
           be very picky and throw out a lot of blobs:
            * too small
            * no line
            - line has too few votes
            - averageLineVariance / lineLength calculations
         - then promote them to outlier groups for further analysis
         */
        if let subtractionImage = subtractionImage {

            self.state = .detectingOutliers1

            // first run the hough transform on sub sections of the subtraction image
            //let houghLines = houghLines(from: subtractionImage)

            self.state = .detectingOutliers2

            let blobber: Blobber = FullFrameBlobber(imageWidth: width,
                                                    imageHeight: height,
                                                    pixelData: subtractionArray,
                                                    frameIndex: frameIndex,
                                                    neighborType: .eight,//.fourCardinal,
                                                    minimumBlobSize: config.minGroupSize/4, // XXX constant XXX
                                                    minimumLocalMaximum: config.maxPixelDistance/2,
                                                    contrastMin: 58)      // XXX constant
/*
 XXX this one misses some blobs because there is no line :(
            let blobber: Blobber = HoughLineBlobber(imageWidth: width,
                                                    imageHeight: height,
                                                    pixelData: subtractionArray,
                                                    frameIndex: frameIndex,
                                                    neighborType: .eight,//.fourCardinal,
                                                    contrastMin: 52,
                                                    houghLines: houghLines)
 */
            
            if config.writeOutlierGroupFiles {
                // save blobs image here
                var blobImageData = [UInt8](repeating: 0, count: width*height)
                for blob in blobber.blobs {
                    for pixel in blob.pixels {
                        blobImageData[pixel.y*width+pixel.x] = 0xFF // make different per blob?
                    }
                }
                let blobImage = PixelatedImage(width: width, height: height,
                                               grayscale8BitImageData: blobImageData)
                try await imageAccessor.save(blobImage, as: .blobs, atSize: .original, overwrite: true)
                try await imageAccessor.save(blobImage, as: .blobs, atSize: .preview, overwrite: true)
            }

            /*
             Now that we have detected blobs in this frame, the next step is to
             collate blobs that are close to the lines and close to eachother into a
             single larger blob.
             */

            self.state = .detectingOutliers2a

            /*
             XXX blob KHT analysis misses existing blobs because of no lines :(
            let blobsToPromote = try await blobKHTAnalysis(houghLines: houghLines,
                                                           blobMap: blobber.blobMap)
             */
            
            var blobsToPromote = blobber.blobs

            // sort by size, biggest first
            blobsToPromote.sort { $0.size > $1.size }
            
            // look for all blobs to promote,
            // and see if we get a better line score if we combine with another 

            var blobsProcessed: [String: Bool] = [:] // keyed by blob id, true if processed

            Log.i("frame \(frameIndex) has \(blobsToPromote.count) blobsToPromote")

            self.state = .detectingOutliers2b

            var filteredBlobs: [Blob] = []

            for blob in blobsToPromote {
                Log.d("frame \(frameIndex) index \(index) filtering blob \(blob)")
                if let blobProcessed = blobsProcessed[blob.id],
                   blobProcessed
                {
                    continue
                }
                var blobToAdd = blob
                blobsProcessed[blob.id] = true

                Log.d("frame \(frameIndex) index \(index) filtering blob \(blob)")

                if let blobLine = blob.line {
                    // search along the line, convolving a small search area across it
                    // search first one direction from the blob center,
                    // then search the other direction from the blob center, to attach
                    // closer blob first
                    
                } else {
                    // search radially, in an ever expanding circle from the center point,
                    // processing closer blobs first
                   
                }
                
                // XXX need to sort other blobs by distance here
                for (innerIndex, innerBlob) in blobsToPromote.enumerated() {

                    if let blobProcessed = blobsProcessed[blob.id],
                       blobProcessed
                    {
                        continue
                    }
                    
                                                                  // XXX constant VVV
                    if blob.boundingBox.edgeDistance(to: innerBlob.boundingBox) > 500 { continue }

                    if let absorbedBlob = blobToAdd.lineMerge(with: innerBlob) {
                        // use this new blob as it is better combined than separate
                        blobToAdd = absorbedBlob
                        // ignore the index of the absorbed blob in the future
                        blobsProcessed[innerBlob.id] = true
                    }
                }
                Log.d("frame \(frameIndex) adding filtered blob \(blobToAdd)")
                filteredBlobs.append(blobToAdd)
            }
            
            Log.i("frame \(frameIndex) has \(filteredBlobs.count) filteredBlobs")
            self.state = .detectingOutliers3
            
            // promote found blobs to outlier groups for further processing
            for blob in filteredBlobs {
                if let _ = blob.line,
                   blob.size >= config.minGroupSize
                {
                    // make outlier group from this blob
                    let outlierGroup = blob.outlierGroup(at: frameIndex)
                    Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.name) line \(blob.line)")
                    outlierGroup.frame = self
                    outlierGroups?.members[outlierGroup.name] = outlierGroup
                }
            }
        } else {
            Log.e("frame \(frameIndex) has no subtraction image, no outliers produced")
        }
        self.state = .readyForInterFrameProcessing
    }

    // returns a list of lines for different sub elements of the given image,
    // sorted so the lines with the highest votes are first
    private func houghLines(from image: PixelatedImage) -> [MatrixElementLine] {
        // XXX A whole forest of magic numbers here :(

        // split the subtraction image into a bunch of small images with some overlap
        let matrix = 
          kernelHoughTransform(elements: image.splitIntoMatrix(maxWidth: 256,
                                                               maxHeight: 256,
                                                               overlapPercent: 70),
                               minVotes: 8000,
                               minResults: 6,
                               maxResults: 20) 
                                          
        var rawElementLines: [MatrixElementLine] = []

        for element in matrix {
            Log.i("frame \(frameIndex) processing matrix element \(element)")
            // first run a kernel based hough transform on this matrix element,
            // returning some set of detected lines 
            if let lines = element.lines {
                for line in lines {
                    rawElementLines.append(MatrixElementLine(element: element,
                                                             line: line,
                                                             frameIndex: frameIndex))
                }
                //Log.i("frame \(frameIndex) appended \(lines.count) lines for element \(element)")
            } else {
                Log.w("frame \(frameIndex) no image for element \(element)")
            }
        }

        Log.i("frame \(frameIndex) loaded raw \(rawElementLines.count) lines")

        // process the lines with most votes first
        rawElementLines.sort { $0.line.votes > $1.line.votes }
        
        log(elements: rawElementLines)
        
        /* 
           combine nearby lines from neighboring elements that line up
           combine their scores, and create a new MatrixElementLine with
           the combined elements
         */

        var filteredLines: [MatrixElementLine] = []

        var processed = [Bool](repeating: false, count: rawElementLines.count)

        // lines closer than this will be combined
        let maxThetaDiff = 8.0  // XXX more constants XXX
        let maxRhoDiff = 8.0

        // filter by combining close lines on neighboring frame elements
        for (baseIndex, baseElement) in rawElementLines.enumerated() {
            if !processed[baseIndex] {
                processed[baseIndex] = true
                var filteredElement = baseElement
                let baseOriginZeroLine = baseElement.originZeroLine
                
                for (index, element) in rawElementLines.enumerated() {
                    if !processed[index] {
                        let thetaDiff = abs(baseElement.line.theta - element.line.theta)
                        // first check theta
                        if thetaDiff < maxThetaDiff {
                            let originZeroLine = element.originZeroLine

                            let rhoDiff = abs(baseOriginZeroLine.rho - originZeroLine.rho)

                            // then check rho after translating to center origin
                            if rhoDiff < maxRhoDiff {
                                filteredElement = baseElement.combine(with: element)
                                processed[index] = true
                            }
                        }
                    }
                }

                filteredLines.append(filteredElement)
            }
        }

        // return the lines with most votes first
        filteredLines.sort { $0.line.votes > $1.line.votes }

        log(elements: filteredLines)
        
        if false,               // XXX this seems to miss some lines that matter :(
           filteredLines.count > 0 {
            let medianIndex = filteredLines.count/2
            let median = filteredLines[medianIndex]

            let medianStripped = Array(filteredLines.prefix(medianIndex))
            log(elements: medianStripped)
            Log.i("frame \(frameIndex) has \(medianStripped.count) filtered lines")
            return medianStripped
        }
        
        Log.i("frame \(frameIndex) has \(filteredLines.count) filtered lines")

        return filteredLines
    }

    private func log(elements: [MatrixElementLine]) {

        if let first = elements.first,
           let last = elements.last
        {
            let median = elements[elements.count/2]

            var totalVotes: Int = 0

            for element in elements {
                totalVotes += element.line.votes
            }

            let mean = Double(totalVotes)/Double(elements.count)

            Log.i("frame \(frameIndex) has \(elements.count) lines votes: first \(first.line.votes) last \(last.line.votes) mean \(mean) median \(median.line.votes)")
        }
    }
    
    // analyze the blobs with kernel hough transform data from the subtraction image
    // filters the blob map, and combines nearby blobs on the same line
    private func blobKHTAnalysis(houghLines: [MatrixElementLine],
                                 blobMap _blobMap: [String: Blob]) async throws -> [Blob]
    {
        var blobsToPromote: [String:Blob] = [:]
        var blobMap = _blobMap   // we need to mutate this arg

        
        let maxVotes = 12000     // lines with votes over this are max color on kht image
        let khtImageBase = 0x1F  // dimmest lines will be 
        var khtImage: [UInt8] = []
        if config.writeOutlierGroupFiles {
            khtImage = [UInt8](repeating: 0, count: width*height)
        }

        // a reference for each pixel for each blob it might belong to
        var blobRefs = [String?](repeating: nil, count: width*height)

        for (key, blob) in blobMap {
            for pixel in blob.pixels {
                blobRefs[pixel.y*width+pixel.x] = blob.id
            }
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
                                   blobsToPromote: &blobsToPromote,
                                   blobRefs: &blobRefs,
                                   blobMap: &blobMap,
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

        return Array(blobsToPromote.values)
    }

    // looks around for blobs close to this place
    private func processBlobsAt(x sourceX: Int,
                                y sourceY: Int,
                                on line: Line,
                                iterationOrientation: IterationOrientation,
                                blobsToPromote: inout [String:Blob],
                                blobRefs: inout [String?],
                                blobMap: inout [String:Blob],
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
                              blobsToPromote: &blobsToPromote,
                              blobRefs: &blobRefs,
                              blobMap: &blobMap,
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
                              blobsToPromote: &blobsToPromote,
                              blobRefs: &blobRefs,
                              blobMap: &blobMap,
                              lastBlob: &lastBlob)
            }
        }
    }

    // process a blob at this particular spot
    private func processBlobAt(x: Int, y: Int,
                               on line: Line,
                               blobsToPromote: inout [String:Blob],
                               blobRefs: inout [String?],
                               blobMap: inout [String:Blob],
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
    
    public func foreachOutlierGroup(_ closure: (OutlierGroup)async->LoopReturn) async {
        if let outlierGroups = self.outlierGroups {
            for (_, group) in outlierGroups.members {
                let result = await closure(group)
                if result == .break { break }
            }
        } 
    }

    // uses spatial 2d array for search
    public func outlierGroups(within distance: Double,
                              of group: OutlierGroup) -> [OutlierGroup]?
    {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.groups(nearby: group)
            var ret: [OutlierGroup] = []
            for otherGroup in groups {
                if otherGroup.bounds.centerDistance(to: group.bounds) < distance {
                    ret.append(otherGroup)
                }
            }
            return ret
        }
        return nil
    }

    // XXX old method
    // XXX this MOFO is slow :(
    public func outlierGroups(within distance: Double,
                              of boundingBox: BoundingBox) -> [OutlierGroup]?
    {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.members
            var ret: [OutlierGroup] = []
            for (_, group) in groups {
                if group.bounds.centerDistance(to: boundingBox) < distance {
                    ret.append(group)
                }
            }
            return ret
        }
        return nil
    }

    public func outlierGroup(named outlierName: String) -> OutlierGroup? {
        return outlierGroups?.members[outlierName]
    }
    
    public func foreachOutlierGroup(between startLocation: CGPoint,
                                    and endLocation: CGPoint,
                                    _ closure: (OutlierGroup)async->LoopReturn) async
    {
        // first get bounding box from start and end location
        var minX: CGFloat = CGFLOAT_MAX
        var maxX: CGFloat = 0
        var minY: CGFloat = CGFLOAT_MAX
        var maxY: CGFloat = 0

        if startLocation.x < minX { minX = startLocation.x }
        if startLocation.x > maxX { maxX = startLocation.x }
        if startLocation.y < minY { minY = startLocation.y }
        if startLocation.y > maxY { maxY = startLocation.y }
        
        if endLocation.x < minX { minX = endLocation.x }
        if endLocation.x > maxX { maxX = endLocation.x }
        if endLocation.y < minY { minY = endLocation.y }
        if endLocation.y > maxY { maxY = endLocation.y }

        let gestureBounds = BoundingBox(min: Coord(x: Int(minX), y: Int(minY)),
                                        max: Coord(x: Int(maxX), y: Int(maxY)))

        await foreachOutlierGroup() { group in
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change paint status
                return await closure(group)
            } else {
                return .continue
            }
        }
    }

    public func maybeApplyOutlierGroupClassifier() async {

        var shouldUseDecisionTree = true
        /*
         logic here to do validation instead of decision tree

         if:
           - we calculated the outlier groups here, not loaded from file
           - and a validation image already exists for this frame
         then:
           - load the validation image
           - don't apply decision tree, use the validation image instead
         */

        if !outliersLoadedFromFile { 
            if let image = await imageAccessor.load(type: .validated, atSize: .original) {
                switch image.imageData {
                case .eightBit(let validationArr):
                    classifyOutliers(with: validationArr)
                    shouldUseDecisionTree = false
                    self.markAsChanged()
                    
                case .sixteenBit(_):
                    Log.e("frame \(frameIndex) cannot load 16 bit validation image")
                }
            } else {
                Log.i("frame \(frameIndex) couldn't load validation image from")
            }
        }
        
        if shouldUseDecisionTree {
            Log.i("frame \(frameIndex) classifying outliers with decision tree")
            self.set(state: .interFrameProcessing)
            await self.applyDecisionTreeToAllOutliers()
        }
    }

    // XXX this method does classify, but does not appear to be saved :(
    private func classifyOutliers(with validationData: [UInt8]) {
        Log.d("frame \(frameIndex) classifying outliers with validation image data")

        if let outlierGroups = outlierGroups {

            for group in outlierGroups.members.values {
                var groupIsValid = false
                for x in 0 ..< group.bounds.width {
                    for y in 0 ..< group.bounds.height {
                        if group.pixels[y*group.bounds.width+x] != 0 {
                            // test this non zero group pixel against the validation image

                            let validationX = group.bounds.min.x + x
                            let validationY = group.bounds.min.y + y
                            let validationIdx = validationY * width + validationX

                            if validationData[validationIdx] != 0 {
                                Log.d("frame \(frameIndex) group \(group.name) is valid based upon validation image data")
                                groupIsValid = true
                                break
                            }
                        }
                    }
                    if groupIsValid { break }
                }
                Log.d("group \(group) shouldPaint \(group.shouldPaint)")
                group.shouldPaint = .userSelected(groupIsValid)
            }
        } else {
            Log.w("cannot classify nil outlier groups")
        }
    }
    
    public func outlierGroupList() -> [OutlierGroup]? {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.members
            return groups.map {$0.value}
        }
        return nil
    }
}

