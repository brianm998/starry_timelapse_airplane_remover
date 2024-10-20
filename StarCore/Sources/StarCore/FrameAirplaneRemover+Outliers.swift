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
    public func loadOutliersFromFile() async throws -> OutlierGroups? {
        let startTime = Date().timeIntervalSinceReferenceDate

        guard let subtractionImage = try await self.imageAccessor.load(type: .subtracted, atSize: .original)
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
                    Log.i("frame \(frameIndex) loaded \(await groups.members.count) outliers in \(endTime-startTime) seconds")

                    
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
        var blobImageSaver: BlobImageSaver? = await .init(blobMap: blobMap,
                                                          width: width,
                                                          height: height,
                                                          frameIndex: frameIndex)
        
        if let blobImageSaver {
            // keep the blobRefs from this for later analysis of nearby outliers
            await outlierGroups?.set(outlierImageData: blobImageSaver.blobRefs)
            await outlierGroups?.set(outlierYAxisImageData: blobImageSaver.yAxis)
            // XXX keep the y-axis too?

            // make sure the OutlierGroups object we created before has this data
            //self.outlierGroups?.outlierImageData = blobImageSaver.blobRefs
        }
        
        let frame_outliers_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"

        mkdir(frame_outliers_dirname)
        
        await blobImageSaver?.save(to: frame_outliers_dirname)

        blobImageSaver = nil

        // blobs to promote to outlier groups
        let blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")
        self.set(state: .populatingOutlierGroups)

        // promote found blobs to outlier groups for further processing
        for blob in blobs {
            // make outlier group from this blob
            let outlierGroup = await blob.outlierGroup(at: frameIndex)

            //Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.id) line \(String(describing: blob.line))")
            await outlierGroup.set(frame: self)
            await outlierGroups?.add(member: outlierGroup)
        }
        self.set(state: .readyForInterFrameProcessing)
    }
    
    public func loadOutliers() async throws {
        if self.outlierGroups == nil {
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = try await loadOutliersFromFile() {
                Log.d("frame \(frameIndex) loading outliers from file")
                for outlier in await outlierGroups.getMembers().values {
                    await outlier.set(frame: self) 
                }

                self.outlierGroups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                self.set(state: .readyForInterFrameProcessing)
                self.outliersLoadedFromFile = true
                Log.i("loaded \(String(describing: await self.outlierGroups?.getMembers().count)) outlier groups for frame \(frameIndex)")
                await self.updateCombineSubjects()
                
            } else {
                Log.d("frame \(frameIndex) calculating outliers")
                self.outlierGroups = OutlierGroups(frameIndex: frameIndex,
                                                   members: [:])

                Log.i("calculating outlier groups for frame \(frameIndex)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await self.findOutliers()

                await self.updateCombineSubjects()
                
                // perhaps apply validation image to outliers here if possible
            }
        }
    }

    public func foreachOutlierGroupAsync(_ closure: @Sendable (OutlierGroup) async -> LoopReturn) async {
        if let outlierGroups {
            for (_, group) in await outlierGroups.getMembers() {
                let result = await closure(group)
                if result == .break { break }
            }
        } 
    }

    // uses spatial 2d array for search
    public func outlierGroups(within distance: Double,
                              of group: OutlierGroup) async -> [OutlierGroup]?
    {
        if let nearbyGroups = await group.nearbyGroups() {
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

    public func outlierGroup(named outlierName: UInt16) async -> OutlierGroup? {
        await outlierGroups?.getMembers()[outlierName]
    }
    
    public func foreachOutlierGroupAsync(between startLocation: CGPoint,
                                         and endLocation: CGPoint,
                                         _ closure: @Sendable (OutlierGroup) async -> LoopReturn) async
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

    public func maybeApplyOutlierGroupClassifier() async throws {

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

        if let image = try await imageAccessor.load(type: .validated, atSize: .original) {
            switch image.imageData {
            case .eightBit(let validationArr):
                await classifyOutliers(with: validationArr)
                shouldUseDecisionTree = false
              await self.markAsChanged()
                
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
    private func classifyOutliers(with validationData: [UInt8]) async {
        Log.d("frame \(frameIndex) classifying outliers with validation image data")

        if let outlierGroups {

            for group in await outlierGroups.getMembers().values {
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
                await group.shouldPaint(.userSelected(groupIsValid))
            }
        } else {
            Log.w("cannot classify nil outlier groups")
        }
    }

    public func outlierGroupList() async -> [OutlierGroup]? {
        if let outlierGroups {
            let groups = await outlierGroups.getMembers()
            return groups.map {$0.value}
        }
        return nil
    }

    // used for saving different images of blobs
    public func saveImages(for blobs: [Blob], as frameImageType: FrameImageType) async throws {
        var blobImageData = [UInt8](repeating: 0, count: width*height)
        for blob in blobs {
            for pixel in await blob.getPixels() {
                blobImageData[pixel.y*width+pixel.x] = 0xFF // make different per blob?
            }
        }
        let fuck = frameImageType
        let blobImage = PixelatedImage(width: width, height: height,
                                       grayscale8BitImageData: blobImageData)
        let (_, _) = await (try imageAccessor.save(blobImage, as: fuck,
                                                   atSize: .original, overwrite: true),
                            try imageAccessor.save(blobImage, as: fuck,
                                                   atSize: .preview, overwrite: true))
        
    }

    public func applyRazor(in boundingBox: BoundingBox) async throws {
        /*
         - find all outliers that have some match with this bounding box
         - remove them from outlier groups list
         - convert them to blobs
         - do intersection with bounding box to create new blob
         - convert all of them back to outlier groups
         */

        if await outlierGroups?.applyRazor(in: boundingBox) ?? false {

            let frame_outliers_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"

            await self.markAsChanged()

            try await outlierGroups?.writeOutliersImage(to: frame_outliers_dirname)

            updateUserSlices(with: boundingBox)
        }
    }

    private func updateUserSlices(with newSlice: BoundingBox) {
        var newSlices: [BoundingBox] = [newSlice]

        // append bounding box to this frame's razor list
        // if any overlap, keep the latest
            
        for slice in userSlices {
            if slice.overlap(with: newSlice) == nil {
                newSlices.append(slice)
            }
        }

        self.userSlices = newSlices
        saveUserSlices()
    }
    
    public func saveUserSlices() {
        let encoder = JSONEncoder()
        do {
            let jsonData = try encoder.encode(self.userSlices)

            let fullPath = self.userSliceFilename
            if FileManager.default.fileExists(atPath: fullPath) {
                try FileManager.default.removeItem(atPath: fullPath)
            } 
            Log.i("creating \(fullPath)")                      
            FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
        } catch {
            Log.e("\(error)")
        }
    }
    
    public func loadUserSlices() async {
        do {
            let dirname = self.userSliceDirname
            let slices_url = NSURL(fileURLWithPath: self.userSliceFilename, isDirectory: false) as URL
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: slices_url))
            let decoder = JSONDecoder()
            self.userSlices = try decoder.decode([BoundingBox].self, from: data)
        } catch {
            //Log.e("cannot load user slices: \(error)")

            mkdir(self.userSliceDirname)
        }
    }
    
    public func deleteOutliers(in boundingBox: BoundingBox) async throws {
        await outlierGroups?.deleteOutliers(in: boundingBox)

        await self.markAsChanged()
        
        let frame_outliers_dirname = "\(self.outlierOutputDirname)/\(frameIndex)"
//        mkdir(frame_outliers_dirname)
        try await outlierGroups?.writeOutliersImage(to: frame_outliers_dirname)
        // XXX add y-axis here too
    }
}
