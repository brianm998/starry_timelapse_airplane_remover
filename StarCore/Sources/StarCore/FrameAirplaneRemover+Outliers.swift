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


/*

 Logic that loads, and finds outliers in a frame.
 
 */
extension FrameAirplaneRemover {

    public func loadOutliers() async throws {
        if self.outlierGroups == nil {
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = await outlierGroupLoader() {
                Log.d("frame \(frameIndex) loading outliers from file")
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
                Log.d("frame \(frameIndex) calculating outliers")
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
        /*
         Outlier Detection Logic:

          - align neighboring frame
          - subtract aligned frame from this frame
          - identify lines on subtracted frame
          - detect blobs from subtracted frame
          - do KHT blob processing
          - do blob absorbsion processing
          - keep only bigger blobs with lines
         
         */
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
         * stick back kht first, but 
         * originally sort blobs by size, processing largest first
         * if a blob can have a line detected from it,
           search along the line by convolving a search area across it to find pixels
           extend some amount past the known blob area on each side of the line
         * if a blob has no line, search in a larger circular area centered on the blob
         * each other nearby blob found is then subject to line analysis,
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

            //self.state = .detectingOutliers1

            // first run the hough transform on sub sections of the subtraction image
            let houghLines = houghLines(from: subtractionImage)

            self.state = .detectingOutliers2

            let blobber: Blobber = FullFrameBlobber(config: config,
                                                    imageWidth: width,
                                                    imageHeight: height,
                                                    pixelData: subtractionArray,
                                                    frameIndex: frameIndex,
                                                    neighborType: .eight,//.fourCardinal,
                                                    minimumBlobSize: config.minGroupSize,
                                                    minimumLocalMaximum: config.maxPixelDistance/4,
                                                    // blobs can grow until the get this much
                                                    // darker than their seed pixel
                                                    // larger values give more blobs
                                                    contrastMin: 62)      // XXX constant
            
            if config.writeOutlierGroupFiles {
                // save blobs image here
                try await saveImages(for: blobber.blobs, as: .blobs)
            }

            Log.d("frame \(frameIndex) starting with \(blobber.blobMap.count) blobs")

            /*
             Now that we have detected blobs in this frame, the next step is to
             weed out small, isolated blobs.  This helps speed things up and,
             if tuned well, doesn't skip anything important.
             */

            self.state = .detectingOutliers2a

            let isolatedRemover = IsolatedBlobRemover(blobMap: blobber.blobMap,
                                                      config: config,
                                                      width: width,
                                                      height: height,
                                                      frameIndex: frameIndex)

            isolatedRemover.process()            

            Log.d("frame \(frameIndex) isolation remover has \(isolatedRemover.blobMap.count) blobs")
            
            /*
             The next step is to collate blobs that are close to the
             lines and close to eachother into a single larger blob.
             */
            let kht = BlobKHTAnalysis(houghLines: houghLines,
                                      blobMap: isolatedRemover.blobMap,
                                      config: config,
                                      width: width,
                                      height: height,
                                      frameIndex: frameIndex,
                                      imageAccessor: imageAccessor)

            try await kht.process()
            if config.writeOutlierGroupFiles {
                // save kht.blobMap image here
                try await saveImages(for: Array(kht.blobMap.values), as: .khtb)
            }
            
            Log.d("frame \(frameIndex) kht analysis done")

            self.state = .detectingOutliers2b

            // XXX these last two steps appear to not help as much as would be nice.
             
            // this mofo is fast as lightning, and seems to mostly work now
            let absorber = BlobAbsorberRewrite(blobMap: kht.blobMap,
                                               config: config,
                                               width: width,
                                               height: height,
                                               frameIndex: frameIndex)

            absorber.process()
                                               
            // look for all blobs to promote,
            // and see if we get a better line score if we combine with another 

            Log.d("frame \(frameIndex) absorber analysis gave \(absorber.blobMap.count) blobs")
            if config.writeOutlierGroupFiles {
                // save filtered blobs image here
                try await saveImages(for: Array(absorber.blobMap.values), as: .absorbed)
            }

            // look for lines that we can extend 
            let blobExtender = BlobLineExtender(pixelData: subtractionArray,
                                                blobMap: absorber.blobMap,
                                                config: config,
                                                width: width,
                                                height: height,
                                                frameIndex: frameIndex)

            blobExtender.process()

            // another pass at trying to unify nearby blobs that fit together
            let blobSmasher = BlobSmasher(blobMap: blobExtender.blobMap,
                                          config: config,
                                          width: width,
                                          height: height,
                                          frameIndex: frameIndex)

            blobSmasher.process()

            let filteredBlobs = Array(blobSmasher.blobMap.values)

            //let filteredBlobs = Array(blobExtender.blobMap.values)

            Log.i("frame \(frameIndex) has \(filteredBlobs.count) filteredBlobs")
            self.state = .detectingOutliers3

            // promote found blobs to outlier groups for further processing
            for blob in filteredBlobs {
                if let _ = blob.line {
                    // first trim pixels too far away
                    //blob.lineTrim() // XXX this kills good blobs :(

                    // XXX apply some kind of brightness / size criteria here?

                    var process = true

                    var threshold = 2000 * Double(config.minGroupSize) / 2 // XXX constants

                    let blobValue = Double(blob.medianIntensity) * Double(blob.size)
                    
                    if blobValue < threshold {
                        // allow smaller groups if they are bright enough
                        //process = false
                    }

                    if process {
                        // make outlier group from this blob
                        let outlierGroup = blob.outlierGroup(at: frameIndex)

                        Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.name) line \(blob.line)")
                        outlierGroup.frame = self
                        outlierGroups?.members[outlierGroup.name] = outlierGroup
                    } else {
                        Log.i("frame \(frameIndex) NOT promoting \(blob)")
                    }
                } else {
                    //Log.i("frame \(frameIndex) NOT promoting \(blob)")
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
                                                               overlapPercent: 50),
                               minVotes: 10000,
                               minResults: 4,
                               maxResults: 10) 
                                          
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

    // used for saving different images of blobs
    public func saveImages(for blobs: [Blob], as frameImageType: FrameImageType) async throws {
        var blobImageData = [UInt8](repeating: 0, count: width*height)
        for blob in blobs {
            for pixel in blob.pixels {
                blobImageData[pixel.y*width+pixel.x] = 0xFF // make different per blob?
            }
        }
        let blobImage = PixelatedImage(width: width, height: height,
                                       grayscale8BitImageData: blobImageData)
        await (try imageAccessor.save(blobImage, as: frameImageType,
                                      atSize: .original, overwrite: true),
               try imageAccessor.save(blobImage, as: frameImageType,
                                      atSize: .preview, overwrite: true))

    }
}

