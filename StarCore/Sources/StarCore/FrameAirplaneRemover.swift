import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

public enum LoopReturn {
    case `continue`
    case `break`
}

public enum FrameProcessingState: Int, CaseIterable, Codable {
    case unprocessed
    case loadingImages    
    case detectingOutliers
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    // XXX add gui check step?
    case reloadingImages
    case painting
    case writingOutputFile
    case complete
}

public class FrameAirplaneRemover: Equatable, Hashable {

    private var state: FrameProcessingState = .unprocessed {
        willSet {
            if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
                frameStateChangeCallback(self, newValue)
            }
        }
    }

    public func processingState() -> FrameProcessingState { return state }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }
    
    func set(state: FrameProcessingState) { self.state = state }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let otherFrameIndexes: [Int] // used in found outliers and paint only
    nonisolated public let frameIndex: Int

    public let outlierOutputDirname: String?
    public let previewOutputDirname: String?
    public let processedPreviewOutputDirname: String?
    public let thumbnailOutputDirname: String?

    // populated by pruning
    public var outlierGroups: OutlierGroups?

    private var didChange = false

    public func changesHandled() { didChange = false }
    
    public func markAsChanged() { didChange = true }

    public func hasChanges() -> Bool { return didChange }
    
    public func outlierGroupList() -> [OutlierGroup]? {
        if let outlierGroups = outlierGroups {
            let groups = outlierGroups.members
            return groups.map {$0.value}
        }
        return nil
    }

    public func outlierGroups(within distance: Double, of boundingBox: BoundingBox) -> [OutlierGroup]? {
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
    
    var previewSize: NSSize {
        let previewWidth = config.previewWidth
        let previewHeight = config.previewHeight
        return NSSize(width: previewWidth, height: previewHeight)
    }
    
    public func writePreviewFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFramePreviewFiles,
           let filename = self.previewFilename
        {
            if fileManager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing preview \(filename)")
                return
            }
            
            Log.d("frame \(self.frameIndex) doing preview")

            if let scaledImage = image.resized(to: self.previewSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                fileManager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    public func writeThumbnailFile(_ image: NSImage) {
        Log.d("frame \(self.frameIndex) doing preview")
        if config.writeFrameThumbnailFiles,
           let filename = self.thumbnailFilename
        {
            if fileManager.fileExists(atPath: filename) {
                Log.i("not overwriting already existing thumbnail filename \(filename)")
                return
            }

            Log.d("frame \(self.frameIndex) doing thumbnail")
            let thumbnailWidth = config.thumbnailWidth
            let thumbnailHeight = config.thumbnailHeight
            let thumbnailSize = NSSize(width: thumbnailWidth, height: thumbnailHeight)
            
            if let scaledImage = image.resized(to: thumbnailSize),
               let imageData = scaledImage.jpegData
            {
                // write to file
                fileManager.createFile(atPath: filename,
                                     contents: imageData,
                                     attributes: nil)
                Log.i("frame \(self.frameIndex) wrote thumbnail to \(filename)")
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        } else {
            Log.d("frame \(self.frameIndex) no config")
        }
    }

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            // write out the decision tree value matrix too

            let valueMatrix = OutlierGroupValueMatrix()

            if let outliers = self.outlierGroupList() {
                for outlier in outliers {
                    await valueMatrix.append(outlierGroup: outlier)
                }
            }

            try valueMatrix.writeCSV(to: "\(outputDirname)/\(self.frameIndex)")
        }
    }

    // write out a directory of individual OutlierGroup binaries
    // for each outlier in this frame
    // large, still not fast, but lots of data
    public func writeOutliersBinary() async {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            do {
                try await self.outlierGroups?.write(to: outputDirname)
            } catch {
                Log.e("error \(error)")
            }                
        }
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                  between startLocation: CGPoint,
                                  and endLocation: CGPoint) async
    {
        await foreachOutlierGroup(between: startLocation, and: endLocation) { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }

    public func applyDecisionTreeToAutoSelectedOutliers() async {
        if let classifier = currentClassifier {
            await withLimitedTaskGroup(of: Void.self) { taskGroup in
                await foreachOutlierGroup() { group in
                    await taskGroup.addMinorTask() {
                        var apply = true
                        if let shouldPaint = group.shouldPaint {
                            switch shouldPaint {
                            case .userSelected(_):
                                // leave user selected ones in place
                                apply = false
                            default:
                                break
                            }
                        }
                        if apply {
                            Log.d("applying decision tree")
                            let score = await classifier.classification(of: group)
                            await group.shouldPaint(.fromClassifier(score))
                        }
                    }
                    return .continue
                }
                await taskGroup.waitForAll()
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches() async {
        await foreachOutlierGroup() { group in
            group.clearFeatureValueCache()
            return .continue
        }
    }

    public func applyDecisionTreeToAllOutliers() async {
        Log.d("frame \(self.frameIndex) applyDecisionTreeToAllOutliers")
        if let classifier = currentClassifier {
            let startTime = NSDate().timeIntervalSince1970
//            await withLimitedTaskGroup(of: Void.self) { taskGroup in
                await foreachOutlierGroup() { group in
                    if group.shouldPaint == nil {
                        // only apply classifier when no other classification is otherwise present
//                        await taskGroup.addTask() {
                            let score = await classifier.classification(of: group)
                            //Log.d("frame \(self.frameIndex) applying classifier shouldPaint \(score)")
                            await group.shouldPaint(.fromClassifier(score))
                        }
  //                  }
                    return .continue
                }
//                await taskGroup.waitForAll()
//            }
            let endTime = NSDate().timeIntervalSince1970
            Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(self.frameIndex) DONE applyDecisionTreeToAllOutliers")
    }
    
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool) async {
        await foreachOutlierGroup() { group in
            await group.shouldPaint(.userSelected(shouldPaint))
            return .continue
        }
    }
    
    var outlierGroupCount: Int { return outlierGroups?.members.count ?? 0 }
    
    public let outputFilename: String

    public let imageSequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    private var outliersLoadedFromFile = false

    public func maybeApplyOutlierGroupClassifier() async {
        self.set(state: .interFrameProcessing)
        await self.applyDecisionTreeToAllOutliers()
    }
    
    public func didLoadOutliersFromFile() -> Bool { outliersLoadedFromFile }
    
    nonisolated public var previewFilename: String? {
        if let previewOutputDirname = previewOutputDirname {
            return "\(previewOutputDirname)/\(baseName).jpg" // XXX this makes it .tif.jpg
        }
        return nil
    }
    
    nonisolated public var processedPreviewFilename: String? {
        if let processedPreviewOutputDirname = processedPreviewOutputDirname {
            return "\(processedPreviewOutputDirname)/\(baseName).jpg"
        }
        return nil
    }
    
    nonisolated public var thumbnailFilename: String? {
        if let thumbnailOutputDirname = thumbnailOutputDirname {
            return "\(thumbnailOutputDirname)/\(baseName).jpg"
        }
        return nil
    }

    let outlierGroupLoader: () async -> OutlierGroups?

    // doubly linked list
    var previousFrame: FrameAirplaneRemover?
    var nextFrame: FrameAirplaneRemover?

    func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }
    
    func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }
    
    let fullyProcess: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool
    
    init(with config: Config,
         width: Int,
         height: Int,
         bytesPerPixel: Int,
         callbacks: Callbacks,
         imageSequence: ImageSequence,
         atIndex frameIndex: Int,
         otherFrameIndexes: [Int],
         outputFilename: String,
         baseName: String,       // source filename without path
         outlierOutputDirname: String?,
         previewOutputDirname: String?,
         processedPreviewOutputDirname: String?,
         thumbnailOutputDirname: String?,
         outlierGroupLoader: @escaping () async -> OutlierGroups?,
         fullyProcess: Bool = true,
         writeOutputFiles: Bool = true) async throws
    {
        self.fullyProcess = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.config = config
        self.baseName = baseName
        self.callbacks = callbacks
        self.outlierGroupLoader = outlierGroupLoader
        
        // XXX this is now only used here for getting the image width, height and bpp
        // XXX this is a waste time
        //let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()
        self.imageSequence = imageSequence
        self.frameIndex = frameIndex // frame index in the image sequence
        self.otherFrameIndexes = otherFrameIndexes
        self.outputFilename = outputFilename

        self.outlierOutputDirname = outlierOutputDirname
        self.previewOutputDirname = previewOutputDirname
        self.processedPreviewOutputDirname = processedPreviewOutputDirname
        self.thumbnailOutputDirname = thumbnailOutputDirname
        self.width = width
        self.height = height

        if ImageSequence.imageWidth == 0 {
            ImageSequence.imageWidth = width
        }
        if ImageSequence.imageHeight == 0 {
            ImageSequence.imageHeight = height
        }
        
        self.bytesPerPixel = bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel

        // this takes a long time, and the gui does it later
        if fullyProcess {
            try await loadOutliers()
            Log.d("frame \(frameIndex) done detecting outlier groups")
            await self.writeOutliersBinary()
            Log.d("frame \(frameIndex) done writing outlier binaries")
        } else {
            Log.d("frame \(frameIndex) loaded without outlier groups")
        }

    }
    
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
            }
        }
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

    public func foreachOutlierGroup(_ closure: (OutlierGroup)async->LoopReturn) async {
        if let outlierGroups = self.outlierGroups {
            for (_, group) in outlierGroups.members {
                let result = await closure(group)
                if result == .break { break }
            }
        } 
    }
    
    // this is still a slow part of the process, but is now about 10x faster than before
    func findOutliers() async throws {

        Log.d("frame \(frameIndex) finding outliers)")
        
        self.state = .loadingImages
        
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        var otherFrames: [PixelatedImage] = []

        for otherFrameIndex in otherFrameIndexes {
            let otherFrame = try await imageSequence.getImage(withName: imageSequence.filenames[otherFrameIndex]).image()
            otherFrames.append(otherFrame)
        }

        self.state = .detectingOutliers
        
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        // one dimentional array mirroring pixels indexed by y*width + x
        var outlierGroupList = [String?](repeating: nil, count: width*height)
        
        Log.i("frame \(frameIndex) finding outliers")
        var outlierAmountList = [UInt](repeating: 0, count: width*height)
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let origData = image.rawImageData

        let otherData1 = otherFrames[0].rawImageData
        var otherData2 = Data() // dummy backup 
        var haveTwoOtherFrames = false
        if otherFrames.count > 1 {
            otherData2 = otherFrames[1].rawImageData
            haveTwoOtherFrames = true
        }

        // most of the time is in this loop, although it's a lot faster now
        // ugly, but a lot faster
        origData.withUnsafeBytes { unsafeRawPointer in 
            let origImagePixels: UnsafeBufferPointer<UInt16> =
                unsafeRawPointer.bindMemory(to: UInt16.self)

            otherData1.withUnsafeBytes { unsafeRawPointer1  in 
                let otherImage1Pixels: UnsafeBufferPointer<UInt16> =
                    unsafeRawPointer1.bindMemory(to: UInt16.self)

                otherData2.withUnsafeBytes { unsafeRawPointer2 in 
                    let otherImage2Pixels: UnsafeBufferPointer<UInt16> =
                        unsafeRawPointer2.bindMemory(to: UInt16.self)

                    for y in 0 ..< height {
                        if y != 0 && y % 1000 == 0 {
                            Log.d("frame \(frameIndex) detected outliers in \(y) rows")
                        }
                        for x in 0 ..< width {
                            let cpp = 3 // number of components per pixel
                            let offset = (y * width*cpp) + (x * cpp)

                            // rgb values of the image we're modifying at this x,y
                            let origRed = origImagePixels[offset]
                            let origGreen = origImagePixels[offset+1]
                            let origBlue = origImagePixels[offset+2]
            
                            // rgb values of an adjecent image at this x,y
                            let other1Red = otherImage1Pixels[offset]
                            let other1Green = otherImage1Pixels[offset+1]
                            let other1Blue = otherImage1Pixels[offset+2]

                            // how much brighter in each channel was the image we're modifying?
                            let other1RedDiff = (Int(origRed) - Int(other1Red))
                            let other1GreenDiff = (Int(origGreen) - Int(other1Green))
                            let other1BlueDiff = (Int(origBlue) - Int(other1Blue))

                            // take a max based upon overal brightness, or just one channel
                            let other1Max = max(other1RedDiff +
                                                    other1GreenDiff +
                                                    other1BlueDiff / 3,
                                                  max(other1RedDiff,
                                                      max(other1GreenDiff,
                                                          other1BlueDiff)))
                            
                            var totalDifference: Int = Int(other1Max)
                            
                            if haveTwoOtherFrames {
                                // rgb values of another adjecent image at this x,y
                                let other2Red = otherImage2Pixels[offset]
                                let other2Green = otherImage2Pixels[offset+1]
                                let other2Blue = otherImage2Pixels[offset+2]
                                
                                // how much brighter in each channel was the image we're modifying?
                                let other2RedDiff = (Int(origRed) - Int(other2Red))
                                let other2GreenDiff = (Int(origGreen) - Int(other2Green))
                                let other2BlueDiff = (Int(origBlue) - Int(other2Blue))
            
                                // take a max based upon overal brightness, or just one channel
                                let other2Max = max(other2RedDiff +
                                                        other2GreenDiff +
                                                        other2BlueDiff / 3,
                                                      max(other2RedDiff,
                                                          max(other2GreenDiff,
                                                              other2BlueDiff)))

                                // average the two differences of the two adjecent frames
                                totalDifference += other2Max
                                totalDifference /= 2
                            }

                            let amountIndex = Int(y*width+x)
                            // record the brightness change if it is brighter
                            if totalDifference > 0  {
                                outlierAmountList[amountIndex] = UInt(totalDifference)
                            }
                        }
                    }
                }
            }
        }

        // XXX was a boundary
        
        Log.i("frame \(frameIndex) pruning outliers")
        
        // go through the outliers and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        
        var individualGroupCounts: [String: UInt] = [:]

        var pendingOutliers: [Int]
        var pendingOutlierInsertIndex = 0;
        var pendingOutlierAccessIndex = 0;
       
        let array = [Int](repeating: -1, count: width*height) 
        pendingOutliers = array

        Log.d("frame \(frameIndex) labeling adjecent outliers")

        // then label all adject outliers
        for (index, outlierAmount) in outlierAmountList.enumerated() {
            
            if outlierAmount <= config.maxPixelDistance { continue }
            
            let outlierGroupname = outlierGroupList[index]
            if outlierGroupname != nil { continue }
            
            // not part of a group yet
            var groupSize: UInt = 0
            // tag this virgin outlier with its own key
            
            let outlierKey = "\(index % width),\(index / width)"; // arbitrary but needs to be unique
            //Log.d("initial index = \(index)")
            outlierGroupList[index] = outlierKey
            pendingOutliers[pendingOutlierInsertIndex] = index;
            pendingOutlierInsertIndex += 1
            
            var loopCount: UInt64 = 0
                
            while pendingOutlierInsertIndex != pendingOutlierAccessIndex {
                //Log.d("pendingOutlierInsertIndex \(pendingOutlierInsertIndex) pendingOutlierAccessIndex \(pendingOutlierAccessIndex)")
                loopCount += 1
                if loopCount % 1000 == 0 {
                    Log.v("frame \(frameIndex) looping \(loopCount) times groupSize \(groupSize)")
                }
                
                let nextOutlierIndex = pendingOutliers[pendingOutlierAccessIndex]
                //Log.d("nextOutlierIndex \(nextOutlierIndex)")
                
                pendingOutlierAccessIndex += 1
               if let _ = outlierGroupList[nextOutlierIndex] {
                    groupSize += 1
                    
                    let outlierX = nextOutlierIndex % width;
                    let outlierY = nextOutlierIndex / width;

                    //Log.e("minPixelDistance \(minPixelDistance) maxPixelDistance \(maxPixelDistance)")
                    
                    if outlierX > 0 { // add left neighbor
                        let leftNeighborIndex = outlierY * width + outlierX - 1
                        let leftNeighborAmount = outlierAmountList[leftNeighborIndex]
                        if leftNeighborAmount > config.minPixelDistance,
                           outlierGroupList[leftNeighborIndex] == nil
                        {
                            pendingOutliers[pendingOutlierInsertIndex] = leftNeighborIndex
                            outlierGroupList[leftNeighborIndex] = outlierKey
                            pendingOutlierInsertIndex += 1
                        }
                    }
                    
                    if outlierX < width - 1 { // add right neighbor
                        let rightNeighborIndex = outlierY * width + outlierX + 1
                        let rightNeighborAmount = outlierAmountList[rightNeighborIndex]
                        if rightNeighborAmount > config.minPixelDistance,
                           outlierGroupList[rightNeighborIndex] == nil
                        {
                            pendingOutliers[pendingOutlierInsertIndex] = rightNeighborIndex
                            outlierGroupList[rightNeighborIndex] = outlierKey
                            pendingOutlierInsertIndex += 1
                        }
                    }
                    
                    if outlierY > 0 { // add top neighbor
                        let topNeighborIndex = (outlierY - 1) * width + outlierX
                        let topNeighborAmount = outlierAmountList[topNeighborIndex]
                        if topNeighborAmount > config.minPixelDistance,
                           outlierGroupList[topNeighborIndex] == nil
                        {
                            pendingOutliers[pendingOutlierInsertIndex] = topNeighborIndex
                            outlierGroupList[topNeighborIndex] = outlierKey
                            pendingOutlierInsertIndex += 1
                        }
                    }
                    
                    if outlierY < height - 1 { // add bottom neighbor
                        let bottomNeighborIndex = (outlierY + 1) * width + outlierX
                        let bottomNeighborAmount = outlierAmountList[bottomNeighborIndex]
                        if bottomNeighborAmount > config.minPixelDistance,
                           outlierGroupList[bottomNeighborIndex] == nil
                        {
                            pendingOutliers[pendingOutlierInsertIndex] = bottomNeighborIndex
                            outlierGroupList[bottomNeighborIndex] = outlierKey
                            pendingOutlierInsertIndex += 1
                        }
                    }
                } else {
                    //Log.w("next outlier has groupName \(String(describing: next_outlier.groupName))")
                    // shouldn't end up here with a group named outlier
                    fatalError("FUCK")
                }
            }
            //Log.d("group \(outlierKey) has \(groupSize) members")
            if groupSize > config.minGroupSize { 
                individualGroupCounts[outlierKey] = groupSize
            }
        }

        var groupAmounts: [String: UInt] = [:] // keyed by group name, average brightness of each group

        Log.i("frame \(frameIndex) calculating outlier group bounds")
        var groupMinX: [String:Int] = [:]   // keyed by group name, image bounds of each group
        var groupMinY: [String:Int] = [:]
        var groupMaxX: [String:Int] = [:]
        var groupMaxY: [String:Int] = [:]
        
        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height {
                let index = y*width+x
                if let group = outlierGroupList[index]
                {
                    let amount = outlierAmountList[index]
                    if let groupAmount = groupAmounts[group] {
                        groupAmounts[group] = groupAmount + amount
                    } else {
                        groupAmounts[group] = amount
                    }
                    if let minX = groupMinX[group] {
                        if(x < minX) {
                            groupMinX[group] = x
                        }
                    } else {
                        groupMinX[group] = x
                    }
                    if let minY = groupMinY[group] {
                        if(y < minY) {
                            groupMinY[group] = y
                        }
                    } else {
                        groupMinY[group] = y
                    }
                    if let maxX = groupMaxX[group] {
                        if(x > maxX) {
                            groupMaxX[group] = x
                        }
                    } else {
                        groupMaxX[group] = x
                    }
                    if let maxY = groupMaxY[group] {
                        if(y > maxY) {
                            groupMaxY[group] = y
                        }
                    } else {
                        groupMaxY[group] = y
                    }
                }
            }
        }

        // populate the outlierGroups
        for (groupName, groupSize) in individualGroupCounts {
            if let minX = groupMinX[groupName],
               let minY = groupMinY[groupName],
               let maxX = groupMaxX[groupName],
               let maxY = groupMaxY[groupName],
               let groupAmount = groupAmounts[groupName]
            {
                let boundingBox = BoundingBox(min: Coord(x: minX, y: minY),
                                               max: Coord(x: maxX, y: maxY))
                let groupBrightness = UInt(groupAmount) / groupSize

                // first apply a height based distinction on the group size,
                // to allow smaller groups lower in the sky, and not higher up.
                // can greatly reduce the outlier group count
                
                // don't do if this bounding box borders an edge
                if minY != 0,
                   minX != 0,
                   maxX < width - 1,
                   maxY < height - 1
                {
                    let groupCenterY = boundingBox.center.y

                    let upperAreaSize = Double(height)*config.upperSkyPercentage/100

                    if groupCenterY < Int(upperAreaSize) {
                        // 1 if at top, 0 if at bottom of the upper area
                        let howCloseToTop = (upperAreaSize - Double(groupCenterY)) / upperAreaSize
                        let minSizeForThisGroup = config.minGroupSize + Int(Double(config.minGroupSizeAtTop - config.minGroupSize) * howCloseToTop)
                        Log.v("minSizeForThisGroup \(minSizeForThisGroup) howCloseToTop \(howCloseToTop) groupCenterY \(groupCenterY) height \(height)")
                        if groupSize < minSizeForThisGroup {
                            Log.v("frame \(frameIndex) skipping group of size \(groupSize) < \(minSizeForThisGroup) @ centerY \(groupCenterY)")
                            continue
                        }
                    }

                }

                // next collect the amounts
                
                var outlierAmounts = [UInt32](repeating: 0, count: boundingBox.width*boundingBox.height)
                for x in minX ... maxX {
                    for y in minY ... maxY {
                        let index = y * self.width + x
                        if let pixelGroupName = outlierGroupList[index],
                           pixelGroupName == groupName
                        {
                            let pixelAmount = outlierAmountList[index]
                            let idx = (y-minY) * boundingBox.width + (x-minX)
                            outlierAmounts[idx] = UInt32(pixelAmount)
                        }
                    }
                }
                
                let newOutlier = await OutlierGroup(name: groupName,
                                                size: groupSize,
                                                brightness: groupBrightness,
                                                bounds: boundingBox,
                                                frame: self,
                                                pixels: outlierAmounts,
                                                maxPixelDistance: config.maxPixelDistance)
                outlierGroups?.members[groupName] = newOutlier
            }
        }
        self.state = .readyForInterFrameProcessing
        Log.i("frame \(frameIndex) has found \(String(describing: outlierGroups?.members.count)) outlier groups to consider")
    }

    public func pixelatedImage() async throws -> PixelatedImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image()
    }

    public func baseImage() async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseOutputImage() async throws -> NSImage? {
        let name = self.outputFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }
    
    public func baseImage(ofSize size: NSSize) async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage(ofSize: size)
    }

    public func purgeCachedOutputFiles() async {
        Log.d("frame \(frameIndex) purging output files")
//        let dispatchGroup = DispatchGroup()
//        dispatchGroup.enter()
        Task {
            await imageSequence.removeValue(forKey: self.outputFilename)
//            dispatchGroup.leave()
        }
//        dispatchGroup.wait()
        Log.d("frame \(frameIndex) purged output files")
    }
    
    // actually paint over outlier groups that have been selected as airplane tracks
    private func paintOverAirplanes(toData data: inout Data,
                                    otherFrames: [PixelatedImage]) async throws
    {
        Log.i("frame \(frameIndex) painting airplane outlier groups")

        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // paint over every outlier in the paint list with pixels from the adjecent frames
        guard let outlierGroups = outlierGroups else {
            Log.e("cannot paint without outlier groups")
            return
        }

        for (_, group) in outlierGroups.members {
            if let reason = group.shouldPaint {
                if reason.willPaint {
                    Log.d("frame \(frameIndex) painting over group \(group) for reason \(reason)")
                    //let x = index % width;
                    //let y = index / width;
                    for x in group.bounds.min.x ... group.bounds.max.x {
                        for y in group.bounds.min.y ... group.bounds.max.y {
                            let pixelIndex = (y - group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                            if group.pixels[pixelIndex] != 0 {
                                
                                let pixelAmount = group.pixels[pixelIndex]
                                
                                var alpha: Double = 0
                                
                                if pixelAmount > config.maxPixelDistance {
                                    alpha = 1
                                } else if pixelAmount < config.minPixelDistance {
                                    alpha = 0
                                } else {
                                    alpha = Double(UInt16(pixelAmount) - config.minPixelDistance) /
                                      Double(config.maxPixelDistance - config.minPixelDistance)
                                }
                                
                                if alpha > 0 {
                                    paint(x: x, y: y, why: reason, alpha: alpha,
                                          toData: &data,
                                          image: image,
                                          otherFrames: otherFrames)
                                }
                            }
                        }
                    }
                } else {
                    Log.v("frame \(frameIndex) NOT painting over group \(group) for reason \(reason)")
                }
            }
        }
    }

    // paint over a selected outlier pixel with data from pixels from adjecent frames
    private func paint(x: Int, y: Int,
                       why: PaintReason,
                       alpha: Double,
                       toData data: inout Data,
                       image: PixelatedImage,
                       otherFrames: [PixelatedImage])
    {
        var pixelsToPaintWith: [Pixel] = []
        
        // grab the pixels from the same image spot from adject frames
//        for i in 0 ..< otherFrames.count {
//            pixelsToPaintWith.append(otherFrames[i].readPixel(atX: x, andY: y))
//        }

        // XXX blending both adjecent frames can make the painted airlane streak darker
        // then it was before because the bright stars are dimmed 50% due to them moving across
        // two frames.  try just using one frame and see how that works.  maybe make it an option?

        
        pixelsToPaintWith.append(otherFrames[0].readPixel(atX: x, andY: y))
        
        // blend the pixels from the adjecent frames
        var paintPixel = Pixel(merging: pixelsToPaintWith)

        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paintPixel = Pixel(merging: paintPixel, with: op, atAlpha: alpha)
        }

        // this is the numeric value we need to write out to paint over the airplane
        var paintValue = paintPixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                             with: &paintValue, count: self.bytesPerPixel)
        
    }

    private func writeUprocessedPreviews(_ image: PixelatedImage) {
        if config.writeFramePreviewFiles ||
           config.writeFrameThumbnailFiles
        {
            Log.d("frame \(self.frameIndex) doing preview")
            if let baseImage = image.baseImage {
                // maybe write previews
                // these are not overwritten as the original
                // is assumed to be not change
                self.writePreviewFile(baseImage)
                self.writeThumbnailFile(baseImage)
            } else {
                Log.w("frame \(self.frameIndex) NO BASE IMAGE")
            }
        }
    }

    private func writeProcssedPreview(_ image: PixelatedImage, with outputData: Data) {
        // write out a preview of the processed file
        if config.writeFrameProcessedPreviewFiles {
            if let processedPreviewImage = image.baseImage(ofSize: self.previewSize,
                                                      fromData: outputData),
               let imageData = processedPreviewImage.jpegData,
               let filename = self.processedPreviewFilename
            {
                do {
                    if fileManager.fileExists(atPath: filename) {
                        Log.i("overwriting already existing processed preview \(filename)")
                        try fileManager.removeItem(atPath: filename)
                    }

                    // write to file
                    fileManager.createFile(atPath: filename,
                                            contents: imageData,
                                            attributes: nil)
                    Log.i("frame \(self.frameIndex) wrote preview to \(filename)")
                } catch {
                    Log.e("\(error)")
                }
            } else {
                Log.w("frame \(self.frameIndex) WTF")
            }
        }
    }

    // run after shouldPaint has been set for each group, 
    // does the final painting and then writes out the output files
    public func finish() async throws {

        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in 

            try await taskGroup.addMinorTask() {
                // write out the outliers binary if it is not there
                // only overwrite the paint reason if it is there
                await self.writeOutliersBinary()
            }
            
            try await taskGroup.addMinorTask() {
                // write out the classifier feature data for this data point
                try await self.writeOutlierValuesCSV()
            }
            
            if !self.writeOutputFiles {
                self.state = .complete
                return
            }
            
            self.state = .reloadingImages
            
            Log.i("frame \(self.frameIndex) finishing")
            let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

            try await taskGroup.addMinorTask() {
                self.writeUprocessedPreviews(image)
            }
        
            var otherFrames: [PixelatedImage] = []

            // only load the first other frame for painting
            let otherFrameIndex = otherFrameIndexes[0]
            let otherFrame = try await imageSequence.getImage(withName: imageSequence.filenames[otherFrameIndex]).image()
            otherFrames.append(otherFrame)
        
            let _data = image.rawImageData
        
            // copy the original image data as adjecent frames need
            // to access the original unmodified version
            guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data
            else {
                Log.e("couldn't copy image data")
                fatalError("couldn't copy image data")
            }
            var outputData = _mut_data

            self.state = .painting
                  
            Log.d("frame \(self.frameIndex) painting over airplanes")
                  
            try await self.paintOverAirplanes(toData: &outputData,
                                          otherFrames: otherFrames)
        
            Log.d("frame \(self.frameIndex) writing output files")
            self.state = .writingOutputFile

            try await taskGroup.addMinorTask() {
                self.writeProcssedPreview(image, with: outputData)
            }

            do {
                // write frame out as a tiff file after processing it
                try image.writeTIFFEncoding(ofData: outputData,  toFilename: self.outputFilename)
                self.state = .complete
            } catch {
                Log.e("\(error)")
            }

            try await taskGroup.waitForAll()

            Log.i("frame \(self.frameIndex) complete")
        }
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}


fileprivate let fileManager = FileManager.default
