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


    // loads outliers from a combination of the outliers.tiff image and the subtraction image,
    // if they are present
    public func loadOutliersFromFile() async -> OutlierGroups? {
        let startTime = Date().timeIntervalSinceReferenceDate

        guard let subtractionImage = await self.imageAccessor.load(type: .subtracted, atSize: .original)
        else {
            Log.i("couldn't load subtraction image for loading outliers")
            return nil
        }

        switch subtractionImage.imageData {
        case .eightBit(_):
            Log.w("cannot process eight bit subtraction image")
            return nil

        case .sixteenBit(let subtractionArr):
            do {
                if let groups = try await OutlierGroups(at: frameIndex,
                                                        withSubtractionArr: subtractionArr,
                                                        fromOutlierDir: "\(self.outlierOutputDirname)/\(frameIndex)")
                {
                    let endTime = Date().timeIntervalSinceReferenceDate
                    Log.i("frame \(frameIndex) loaded \(groups.members.count) outliers in \(endTime-startTime) seconds")
                    return groups
                }
            } catch {
                Log.e("frame \(frameIndex) cannot load outlier groups: \(error)")
            }
        }
        return nil
    }

    public func findOutliers() async throws {
        
        let blobMap = try await BlobProcessor(frame: self).run()

        // save blobs to blob image here
        var blobImageSaver: BlobImageSaver? = .init(blobMap: blobMap,
                                                    width: width,
                                                    height: height,
                                                    frameIndex: frameIndex)

        if let blobImageSaver {
            // keep the blobRefs from this for later analysis of nearby outliers
            outlierGroups?.outlierImageData = blobImageSaver.blobRefs
            outlierGroups?.outlierYAxisImageData = blobImageSaver.yAxis
            // XXX keep the y-axis too?

            // make sure the OutlierGroups object we created before has this data
            self.outlierGroups?.outlierImageData = blobImageSaver.blobRefs
        }
        
        let frame_outliers_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"

        mkdir(frame_outliers_dirname)
        
        blobImageSaver?.save(to: frame_outliers_dirname)

        blobImageSaver = nil

        // blobs to promote to outlier groups
        let blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")
        self.state = .populatingOutlierGroups

        // promote found blobs to outlier groups for further processing
        for blob in blobs {
            // make outlier group from this blob
            let outlierGroup = blob.outlierGroup(at: frameIndex)

            //Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.id) line \(String(describing: blob.line))")
            outlierGroup.frame = self
            outlierGroups?.members[outlierGroup.id] = outlierGroup
        }
        self.state = .readyForInterFrameProcessing
    }
    
    public func loadOutliers() async throws {
        if self.outlierGroups == nil {
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = await loadOutliersFromFile() {
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

    public func foreachOutlierGroup(_ closure: (OutlierGroup) -> LoopReturn) {
        if let outlierGroups = self.outlierGroups {
            for (_, group) in outlierGroups.members {
                let result = closure(group)
                if result == .break { break }
            }
        } 
    }

    public func foreachOutlierGroupAsync(_ closure: (OutlierGroup) async -> LoopReturn) async {
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
        if let nearbyGroups = group.nearbyGroups {
            var ret: [OutlierGroup] = []
            for nearbyGroup in nearbyGroups {
                if nearbyGroup.bounds.centerDistance(to: group.bounds) < distance {
                    ret.append(nearbyGroup)
                }
            }
            return ret
        }
        return nil
    }

    public func outlierGroup(named outlierName: UInt16) -> OutlierGroup? {
        return outlierGroups?.members[outlierName]
    }
    
    public func foreachOutlierGroup(between startLocation: CGPoint,
                                    and endLocation: CGPoint,
                                    _ closure: (OutlierGroup) -> LoopReturn) 
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

        if let minX = minX.int,
           let minY = minY.int,
           let maxX = maxX.int,
           let maxY = maxY.int
        {
            let gestureBounds = BoundingBox(min: Coord(x: minX, y: minY),
                                            max: Coord(x: maxX, y: maxY))

            foreachOutlierGroup() { group in
                if gestureBounds.contains(other: group.bounds) {
                    // check to make sure this outlier's bounding box is fully contained
                    // otherwise don't change paint status
                    return closure(group)
                } else {
                    return .continue
                }
            }
        }
    }

    public func foreachOutlierGroupAsync(between startLocation: CGPoint,
                                         and endLocation: CGPoint,
                                         _ closure: (OutlierGroup) async -> LoopReturn) async
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

        await foreachOutlierGroupAsync() { group in
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
/*
        if config.writeOutlierGroupFiles,
           let outlierGroups
        {
            // calculate decision tree values first 
            for group in outlierGroups.members.values {
                let _ = group.decisionTreeValues
            }
        }
  */      
        if shouldUseDecisionTree {
            Log.i("frame \(frameIndex) classifying outliers with decision tree")
            self.set(state: .interFrameProcessing)
            await self.applyDecisionTreeToAllOutliers()
        }
    }

    // used to classify outliers given a validation image.
    // this validation image contains a non zero pixel for each outlier
    // that should be painted over.
    // any outlier that matches any pixels is classified to paint here.
    private func classifyOutliers(with validationData: [UInt8]) {
        Log.d("frame \(frameIndex) classifying outliers with validation image data")

        if let outlierGroups {

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
                                //Log.d("frame \(frameIndex) group \(group.id) is valid based upon validation image data")
                                groupIsValid = true
                                break
                            }
                        }
                    }
                    if groupIsValid { break }
                }
                //Log.d("group \(group) shouldPaint \(String(describing: group.shouldPaint))")
                group.shouldPaint = .userSelected(groupIsValid)
            }
        } else {
            Log.w("cannot classify nil outlier groups")
        }
    }

    public func outlierGroupList() -> [OutlierGroup]? {
        if let outlierGroups {
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
        let (_, _) = await (try imageAccessor.save(blobImage, as: frameImageType,
                                                   atSize: .original, overwrite: true),
                            try imageAccessor.save(blobImage, as: frameImageType,
                                                   atSize: .preview, overwrite: true))
        
    }

    public func deleteOutliers(in boundingBox: BoundingBox) throws {
        outlierGroups?.deleteOutliers(in: boundingBox)

        let frame_outliers_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"
//        mkdir(frame_outliers_dirname)
        try outlierGroups?.writeOutliersImage(to: frame_outliers_dirname)
        // XXX add y-axis here too
    }
}
