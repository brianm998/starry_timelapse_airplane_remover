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

fileprivate let outliersFileSystemMonitor = FileSystemMonitor(max: 50)

public struct OutlierSorter: Sendable {
    public let classification: Double
    public let outlier: OutlierGroup
}

extension FrameAirplaneRemover {


    // loads outliers from a combination of the outliers.tiff image and the subtraction image,
    // if they are present
    public func loadOutliersFromFile() async throws -> OutlierGroups? {
        try await outliersFileSystemMonitor.load() {
            do {
                // newer file format, default to this
                return try await loadOutliersFromBinaryFile()
            } catch {
                // XXX log here
            }

            return nil
        }
    }

    public var blobBinaryFilename: String { // not used anymore?
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)/\(BlobBinarySaver.outlierBinaryFilename)"
        }
    }
    
    public func loadOutliersFromBinaryFile() async throws -> OutlierGroups? {
        let config = await configManager.config()
        let dirname = "\(config.outlierOutputDirname)/\(frameIndex)"

        return try await OutlierGroups(at: frameIndex, fromOutlierDir: dirname)
    }
    
    public func findOutliers() async throws {
        
        mkdir(await self.outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor
        
        let blobMap = try await blobProcessor.process(frame: self)

        // blobs to promote to outlier groups
        let blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")
        self.set(state: .populatingOutlierGroups)

        let classifier = IoslatedOutlierClassifier(frameIndex: frameIndex, frame: self)
        let (good, bad) = await classifier.promoteAndClassify(blobs)

        await self.outlierGroups?.add(good)
        await self.outlierGroups?.dumpInDustbin(bad)
        
        // here we write the outlier binaries through the outlierGroups
        try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)

        // XXX update UI
        
        self.set(state: .readyForInterFrameProcessing)
    }

//    public func outliersLoaded() { self.outlierGroups != nil }

    public func loadOutliers(loadOnly: Bool = false) async throws {
        if isLoadingOutliers { return }
        isLoadingOutliers = true
        if self.outlierGroups == nil {
            // nil outlier groups means that we haven't tried to get outliers for this frame yet
            Log.d("frame \(frameIndex) loading outliers")
            if let outlierGroups = try await loadOutliersFromFile() {
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loading)
                Log.d("frame \(frameIndex) loading outliers from file")
                for outlier in await outlierGroups.getMembers().values {
                    await outlier.set(frame: self) 
                }

                self.outlierGroups = outlierGroups
                // while these have already decided outlier groups,
                // we still need to inter frame process them so that
                // frames are linked with their neighbors and outlier
                // groups can use these links for decision tree values
                self.outliersLoadedFromFile = true
                Log.i("loaded \(String(describing: await self.outlierGroups?.getMembers().count)) outlier groups for frame \(frameIndex)")
                await self.updateCombineSubjects()
                
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loaded)
            } else if !loadOnly {
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loading)
                Log.d("frame \(frameIndex) calculating outliers")
                self.initializeEmptyOutlierGroups()

                Log.i("calculating outlier groups for frame \(frameIndex)")
                // find outlying bright pixels between frames,
                // and group neighboring outlying pixels into groups
                // this can take a long time
                try await self.findOutliers()

                await self.updateCombineSubjects()
                
                // perhaps apply validation image to outliers here if possible
                callbacks.frameOutliersLoadedCallback?(frameIndex, .loaded)
            }
        }
        isLoadingOutliers = false
    }

    public func initializeEmptyOutlierGroups() {
        self.outlierGroups = OutlierGroups(frameIndex: frameIndex)
    }
    
    public func foreachOutlierGroup(includingDustbin: Bool,
                                    _ closure: @Sendable (OutlierGroup, Bool) async -> Void) async
    {
        if let outlierGroups {
            for (_, group) in await outlierGroups.getMembers() {
                await closure(group, false)
            }
            for (_, group) in await outlierGroups.getDustbin() {
                await closure(group, true)
            }
        } 
    }

    public func foreachOutlierGroupMulti(includingDustbin: Bool,
                                         _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Void) async
    {
        if let outlierGroups {
            await withTaskGroup(of: Void.self) { taskGroup in
                for (_, group) in await outlierGroups.getMembers() {
                    taskGroup.addTask() { await closure(group, false) }
                }
                for (_, group) in await outlierGroups.getDustbin() {
                    taskGroup.addTask() { await closure(group, true) }
                }
                await taskGroup.waitForAll()
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

    public func foreachOutlierGroupMulti(between startLocation: CGPoint,
                                         and endLocation: CGPoint,
                                         includingDustbin: Bool, 
                                         _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Void) async
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
        
        await foreachOutlierGroupMulti(includingDustbin: includingDustbin) { group, isInDustbin in
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change paint status
                await closure(group, isInDustbin)
            }
        }
    }

    public func maybeApplyOutlierGroupClassifier(includingDustbin: Bool) async throws {

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

        if let image = try await imageAccessor.load(frameIndex: frameIndex,
                                                    type: .validation,
                                                    atSize: .original)
        {
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
            await self.applyDecisionTreeToAllOutliers(includingDustbin: includingDustbin)
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

    public func outlierGroupDustbinList() async -> [OutlierGroup]? {
        if let outlierGroups {
            let groups = await outlierGroups.getDustbin()
            return groups.map {$0.value}
        }
        return nil
    }

    // used for saving different images of blobs
    public func saveImages(for blobs: [Blob], as frameImageType: FrameViewMode) async throws {
        var blobImageData = [UInt8](repeating: 0, count: width*height)
        for blob in blobs {
            for pixel in await blob.getPixels() {
                let imageIntensity = pixel.intensity >> 8
                blobImageData[pixel.y*width+pixel.x] = UInt8(imageIntensity)//0xFF // make different per blob?
            }
        }
        let fuck = frameImageType
        let blobImage = PixelatedImage(width: width, height: height,
                                       grayscale8BitImageData: blobImageData)
        let (_) = await (/*try imageAccessor.save(blobImage, as: fuck,
                                                   atSize: .original, overwrite: true),*/
          try imageAccessor.save(blobImage,
                                 frameIndex: frameIndex,
                                 as: fuck,
                                 atSize: .preview, overwrite: true))
        
    }

    public func applyRazor(in boundingBox: BoundingBox, includingDustbin: Bool) async throws {
        /*
         - find all outliers that have some match with this bounding box
         - remove them from outlier groups list
         - convert them to blobs
         - do intersection with bounding box to create new blob
         - convert all of them back to outlier groups
         */

        if await outlierGroups?.applyRazor(in: boundingBox,
                                           includingDustbin: includingDustbin) ?? false
        {
            await self.markAsChanged()

            try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)

            await updateUserSlices(with: boundingBox)
        }
    }

    private func updateUserSlices(with newSlice: BoundingBox) async {

        if userSlices == nil { await self.loadUserSlices() }

        guard let userSlices else { return }
        
        // XXX update this to load them first if not present
        
        var newSlices: [BoundingBox] = [newSlice]

        // append bounding box to this frame's razor list
        // if any overlap, keep the latest
            
        for slice in userSlices {
            if slice.overlap(with: newSlice) == nil {
                newSlices.append(slice)
            }
        }

        self.userSlices = newSlices
        await saveUserSlices()
    }
    
    public func saveUserSlices() async {
        guard let userSlices else { return }
        let encoder = JSONEncoder()
        do {
            let jsonData = try encoder.encode(userSlices)

            let fullPath = await self.userSliceFilename
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
            let slices_url = NSURL(fileURLWithPath: await self.userSliceFilename,
                                   isDirectory: false) as URL
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: slices_url))
            let decoder = JSONDecoder()
            self.userSlices = try decoder.decode([BoundingBox].self, from: data)
        } catch {
            //Log.e("cannot load user slices: \(error)")

            mkdir(await self.userSliceDirname)
        }
    }

    public var outliersDirname: String {
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)"
        }
    }

    public func promoteDust(in boundingBox: BoundingBox) async throws -> [OutlierGroup] {
        guard let outlierGroups else { return [] }
        let ret = await outlierGroups.promoteDust(in: boundingBox)

        await self.markAsChanged()
        
        try await outlierGroups.writeOutliersBinary(to: self.outliersDirname)

        return ret
    }
    
    public func deleteOutliers(in boundingBox: BoundingBox) async throws {
        await outlierGroups?.deleteOutliers(in: boundingBox)

        await self.markAsChanged()
        
        try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)
        // XXX add y-axis here too
    }
}


fileprivate class IoslatedOutlierClassifier {

    let frameIndex: Int
    let frame: FrameAirplaneRemover
    
    public init(frameIndex: Int,
                frame: FrameAirplaneRemover)
    {
        self.frameIndex = frameIndex
        self.frame = frame
    }
    
    func promoteAndClassify(_ blobs: [Blob]) async -> ([OutlierGroup], [OutlierGroup]) {
        let frame = self.frame
        let frameIndex = self.frameIndex
        
        return await Task.detached {
            await withTaskGroup(of: OutlierSorter.self) { taskGroup in
                // promote found blobs to outlier groups for further processing
                let classifier = await currentClassifier.get(for: .isolated) 
                
                for blob in blobs {
                    taskGroup.addTask {
                        // make outlier group from this blob
                        let outlierGroup = await blob.outlierGroup(at: frameIndex)

                        //Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.id) line \(String(describing: blob.line))")
                        await outlierGroup.set(frame: frame)

                        // when promoting blobs to outlier groups, we first use the .isolated classifier
                        // and separate blobs into two groups based upon a threshold in this classification.
                        // one group is the dustbin, which has a very high likelyhood of not being useful
                        // the other group are the outlier groups that will get processed further

                        if let classifier {
                            let featureData = await outlierGroup.featureData(for: .isolated)
                            let classification = classifier.classification(of: featureData)

                            // -1 classification means bad
                            //  1 classification means good
                            //  0 is undecided
                            return OutlierSorter(classification: classification,
                                                 outlier: outlierGroup)
                        } else {
                            Log.w("No .isolated classifier!!") // assume it's good
                            return OutlierSorter(classification: 1,
                                                 outlier: outlierGroup)
                        }
                    }
                }

                var good: [OutlierGroup] = []
                var bad: [OutlierGroup] = []
                
                for await value in taskGroup {
                    if value.classification > -0.15 { // XXX constant XXX expose this XXX
                        // it's good
                        good.append(value.outlier)
                    } else {
                        // it's bad
                        bad.append(value.outlier)
                    }
                }

                return (good, bad)
            }
        }.value
    }
}
