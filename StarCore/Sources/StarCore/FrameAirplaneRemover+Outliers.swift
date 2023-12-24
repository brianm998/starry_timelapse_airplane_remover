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

        Log.d("frame \(frameIndex) finding outliers)")

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

        self.state = .detectingOutliers1

        let blobber = Blobber(imageWidth: width,
                              imageHeight: height,
                              pixelData: subtractionArray,
                              neighborType: .eight,//.fourCardinal,
                              minimumBlobSize: config.minGroupSize,
                              minimumLocalMaximum: config.maxPixelDistance,
                              contrastMin: 58)      // XXX constant

        self.state = .detectingOutliers2

        var blobsToPromote: [Blob] = []
        var lastBlob: Blob?

        /*
         Now that we have detected blobs in this frame, the next step is to
         identify lines in the frame and collate blobs that are close to the lines
         and close to eachother into a single larger blob.
         */
        if let subtractionImage = subtractionImage {

            Log.i("frame \(frameIndex) loaded subtraction image")

            // XXX A whole forest of magic numbers here :(
            let matrix = subtractionImage.splitIntoMatrix(maxWidth: 1024, maxHeight: 1024)
            Log.i("frame \(frameIndex) has matrix with \(matrix.count) elements")
            for element in matrix {
                Log.i("frame \(frameIndex) matrix element [\(element.x), \(element.y)]")

                let lines = await element.image.kernelHoughTransform(maxThetaDiff: 10,
                                                                     maxRhoDiff: 10,
                                                                     minVotes: 2000,
                                                                     minResults: 6)

                // get list of blobs in this element 
                var blobsToProcess = blobber.blobs.filter { $0.isIn(matrixElement: element) }
                
                Log.i("frame \(frameIndex) \(blobsToProcess.count) blobs blobber.blobs \(blobber.blobs) and \(lines.count) lines")

                for line in lines {
                    let frameEdgeMatches = line.frameBoundries(width: element.image.width,
                                                               height: element.image.height)
                    if frameEdgeMatches.count == 2 {
                        // sunny day case
                        Log.d("frame \(frameIndex) frameEdgeMatches \(frameEdgeMatches[0]) \(frameEdgeMatches[1])")
                        let line = StandardLine(point1: frameEdgeMatches[0],
                                                point2: frameEdgeMatches[1])
                        
                        let x_diff = abs(frameEdgeMatches[0].x - frameEdgeMatches[1].x)
                        let y_diff = abs(frameEdgeMatches[0].y - frameEdgeMatches[1].y)
                        
                        let iterateOnXAxis = x_diff > y_diff
                        
                        if iterateOnXAxis {
                            for x in 0..<element.image.width {
                                let y = Int(line.y(forX: Double(x)))
                                if y > 0,
                                   y < element.image.height
                                {
                                    let (foo, bar) =
                                      processBlobsAt(x: x+element.x,
                                                     y: y+element.y,
                                                     blobsToProcess: blobsToProcess,
                                                     blobsToPromote: &blobsToPromote,
                                                     lastBlob: lastBlob)

                                    blobsToProcess = foo
                                    lastBlob = bar
                                }
                            }
                        } else {
                            // iterate on y axis
                            for y in 0..<element.image.height {
                                let x = Int(line.x(forY: Double(y)))
                                if x > 0,
                                   x < element.image.width
                                {
                                    let (foo, bar) =
                                      processBlobsAt(x: x+element.x,
                                                     y: y+element.y,
                                                     blobsToProcess: blobsToProcess,
                                                     blobsToPromote: &blobsToPromote,
                                                     lastBlob: lastBlob)

                                    blobsToProcess = foo
                                    lastBlob = bar
                                }
                            }
                        }
                    } else {
                        Log.e("frame \(frameIndex) frameEdgeMatches.count \(frameEdgeMatches.count) != 2")
                    }
                }
            }
        } else {
            Log.e("no subtraction image")
        }

        Log.d("frame \(frameIndex) has \(blobsToPromote) blobsToPromote")
        self.state = .detectingOutliers3

        // promote found blobs to outlier groups for further processing
        for blob in blobsToPromote {
            // make outlier group from this blob
            let outlierGroup = blob.outlierGroup(at: frameIndex)
            outlierGroup.frame = self
            outlierGroups?.members[outlierGroup.name] = outlierGroup
        }
        
        self.state = .readyForInterFrameProcessing
    }
        
    private func processBlobsAt(x: Int,
                                y: Int,
                                blobsToProcess: [Blob],
                                blobsToPromote: inout [Blob],
                                lastBlob: Blob?) -> ([Blob], Blob?)
    {
        var blobsNotProcessed: [Blob] = []
        var lastBlob_ = lastBlob
        for blob in blobsToProcess {
            let blobDistance = blob.distanceTo(x: x, y: y)
            //Log.d("frame \(frameIndex) blobDistance \(blobDistance)")
            if blobDistance < 10 { // XXX magic number XXX
                if let _lastBlob = lastBlob {
                    if _lastBlob.boundingBox.edgeDistance(to: blob.boundingBox) < 20 { // XXX constant XXX
                        // if they are close enough, simply combine them
                        _lastBlob.absorb(blob)
                        Log.d("frame \(frameIndex) absorbing blob")
                    } else {
                        // if they are far, then overwrite the lastBlob var
                        blobsToPromote.append(blob)
                        lastBlob_ = blob
                        //Log.d("frame \(frameIndex) blobDistance \(blobDistance) too far")
                    }
                } else {
                    Log.d("frame \(frameIndex) no last blob")
                    blobsToPromote.append(blob)
                    lastBlob_ = blob
                }
            } else {
                //Log.d("frame \(frameIndex) distance too far, not processing blob")
                blobsNotProcessed.append(blob)
            }
        }
        return (blobsNotProcessed, lastBlob_)
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
                    
                case .sixteenBit(_):
                    Log.e("frame \(frameIndex) cannot load 16 bit validation image")
                }
            } else {
                Log.i("frame \(frameIndex) couldn't load validation image from")
            }
        }
        
        if shouldUseDecisionTree {
            Log.d("frame \(frameIndex) classifying outliers with decision tree")
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
                                    //Log.d("frame \(frameIndex) group \(group.name) is valid based upon validation image data")
                                groupIsValid = true
                                break
                            }
                        }
                    }
                    if groupIsValid { break }
                }
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
