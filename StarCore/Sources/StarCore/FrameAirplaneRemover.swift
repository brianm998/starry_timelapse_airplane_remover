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
    case starAlignment    
    case loadingImages    
    case detectingOutliers
    case detectingOutliers1
    case detectingOutliers2
    case detectingOutliers3
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    // XXX add gui check step?

    case writingBinaryOutliers
    case writingOutlierValues
    
    case reloadingImages
    case painting
    case writingOutputFile
    case complete
}

fileprivate class OutlierGroupInfo {
    var amount: UInt = 0 // average brightness of each group
    var minX: Int?
    var minY: Int?
    var maxX: Int?
    var maxY: Int?
    func process(x: Int, y: Int, amount: UInt) {
        self.amount += amount
        if let minX = minX {
            if x < minX { self.minX = x }
        } else {
            minX = x
        }
        if let minY = minY {
            if y < minY { self.minY = y }
        } else {
            minY = y
        }
        if let maxX = maxX {
            if x > maxX { self.maxX = x }
        } else {
            maxX = x
        }
        if let maxY = maxY {
            if y > maxY { self.maxY = y }
        } else {
            maxY = y
        }
    }
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
    nonisolated public let frameIndex: Int

    public let outlierOutputDirname: String?
    public let previewOutputDirname: String?
    public let processedPreviewOutputDirname: String?
    public let thumbnailOutputDirname: String?
    public let starAlignedSequenceDirname: String
    public var starAlignedSequenceFilename: String {
        "\(starAlignedSequenceDirname)/\(baseName)"
    }
    public let alignedSubtractedDirname: String
    public var alignedSubtractedFilename: String {
        "\(alignedSubtractedDirname)/\(baseName)"
    }
    
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

        Log.d("frame \(self.frameIndex) writeOutlierValuesCSV")
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            // write out the decision tree value matrix too
            Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1")

            let frameOutlierDir = "\(outputDirname)/\(self.frameIndex)"
            let positiveFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
            let negativeFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.negativeDataFilename)"

            // check to see if both of these files exist already
            if fileManager.fileExists(atPath: positiveFilename),
               fileManager.fileExists(atPath: negativeFilename) {
                Log.i("frame \(self.frameIndex) not recalculating outlier values with existing files")
            } else {
                let valueMatrix = OutlierGroupValueMatrix()
                
                if let outliers = self.outlierGroupList() {
                    Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1a \(outliers.count) outliers")
                    for outlier in outliers {
                        Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1b")
                        await valueMatrix.append(outlierGroup: outlier)
                    }
                }
                Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 2")

                try valueMatrix.writeCSV(to: frameOutlierDir)
                Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 3")
            }
        }
        Log.d("frame \(self.frameIndex) DONE writeOutlierValuesCSV")
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
                    await taskGroup.addTask() {
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
                            let score = classifier.classification(of: group)
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
        Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(self.outlierGroups?.members.count ?? 0) Outliers")
        if let classifier = currentClassifier {
            let startTime = NSDate().timeIntervalSince1970
            await withLimitedTaskGroup(of: Void.self) { taskGroup in
                await foreachOutlierGroup() { group in
                    if group.shouldPaint == nil {
                        // only apply classifier when no other classification is otherwise present
                        await taskGroup.addTask() {
                            let values = await group.decisionTreeValues
                            let valueTypes = OutlierGroup.decisionTreeValueTypes

                            let score = classifier.classification(of: valueTypes, and: values)
                            await group.shouldPaint(.fromClassifier(score))
                        }
                    }
                    return .continue
                }
                await taskGroup.waitForAll()
            }
            let endTime = NSDate().timeIntervalSince1970
            Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
        } else {
            Log.i("no classifier")
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
         outputFilename: String,
         baseName: String,       // source filename without path
         outlierOutputDirname: String?,
         previewOutputDirname: String?,
         processedPreviewOutputDirname: String?,
         thumbnailOutputDirname: String?,
         starAlignedSequenceDirname: String,
         alignedSubtractedDirname: String,
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
        self.imageSequence = imageSequence
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename

        self.outlierOutputDirname = outlierOutputDirname
        self.previewOutputDirname = previewOutputDirname
        self.processedPreviewOutputDirname = processedPreviewOutputDirname
        self.thumbnailOutputDirname = thumbnailOutputDirname
        self.starAlignedSequenceDirname = starAlignedSequenceDirname
        self.alignedSubtractedDirname = alignedSubtractedDirname
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

        // align a neighboring frame for detection

        self.state = .starAlignment
        // call directly in init becuase didSet() isn't called from here :P
        if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, self.state)
        }
        
        Log.i("frame \(frameIndex) doing star alignment")
        let baseFilename = imageSequence.filenames[frameIndex]
        var otherFilename: String = ""
        if frameIndex == imageSequence.filenames.count-1 {
            // if we're at the end, take the previous frame
            otherFilename = imageSequence.filenames[imageSequence.filenames.count-2]
        } else {
            // otherwise, take the next frame
            otherFilename = imageSequence.filenames[frameIndex+1]
        }
        _ = StarAlignment.align(otherFilename,
                                to: baseFilename,
                                inDir: starAlignedSequenceDirname)
        
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

    private func subtractAlignedImageFromFrame() async throws -> [UInt16] {
        self.state = .loadingImages
        
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // use star aligned image
        let otherFrame = try await imageSequence.getImage(withName: starAlignedSequenceFilename).image()

        self.state = .detectingOutliers
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        Log.i("frame \(frameIndex) finding outliers")
        // XXX write this out as a 16 bit monochrome image
        var subtractionArray = [UInt16](repeating: 0, count: width*height)
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let origData = image.rawImageData

        let otherData = otherFrame.rawImageData

        // most of the time is in this loop, although it's a lot faster now
        // ugly, but a lot faster
        origData.withUnsafeBytes { unsafeRawPointer in 
            let origImagePixels: UnsafeBufferPointer<UInt16> =
                unsafeRawPointer.bindMemory(to: UInt16.self)

            otherData.withUnsafeBytes { unsafeRawPointer1  in 
                let otherImagePixels: UnsafeBufferPointer<UInt16> =
                  unsafeRawPointer1.bindMemory(to: UInt16.self)

                for y in 0 ..< height {
                    for x in 0 ..< width {
                        let origOffset = (y * width*image.pixelOffset) +
                                         (x * image.pixelOffset)
                        let otherOffset = (y * width*otherFrame.pixelOffset) +
                                          (x * otherFrame.pixelOffset)
                        
                        var maxBrightness: Int32 = 0
                        
                        if otherFrame.pixelOffset == 4,
                           otherImagePixels[otherOffset+3] != 0xFFFF
                        {
                            // ignore any partially or fully transparent pixels
                            // these crop up in the star alignment images
                            // there is nothing to copy from these pixels
                        } else {
                            // rgb values of the image we're modifying at this x,y
                            let origRed = Int32(origImagePixels[origOffset])
                            let origGreen = Int32(origImagePixels[origOffset+1])
                            let origBlue = Int32(origImagePixels[origOffset+2])
                            
                            // rgb values of an adjecent image at this x,y
                            let otherRed = Int32(otherImagePixels[otherOffset])
                            let otherGreen = Int32(otherImagePixels[otherOffset+1])
                            let otherBlue = Int32(otherImagePixels[otherOffset+2])

                            maxBrightness += origRed + origGreen + origBlue
                            maxBrightness -= otherRed + otherGreen + otherBlue
                        }
                        // record the brightness change if it is brighter
                        if maxBrightness > 0 {
                            subtractionArray[y*width+x] = UInt16(maxBrightness/3)
                        }
                    }
                }
            }
        }

        if config.writeOutlierGroupFiles {
            // write out image of outlier amounts
            do {
                try saveSubtractionImage(subtractionArray)
                Log.d("frame \(frameIndex) saved subtraction image")
            } catch {
                Log.e("can't write subtraction image: \(error)")
            }
        }
        
        return subtractionArray
    }
    
    // this is still a slow part of the process, but is now about 10x faster than before
    func findOutliers() async throws {

        Log.d("frame \(frameIndex) finding outliers)")

        // contains the difference in brightness between the frame being processed
        // and its aligned neighbor frame.  Indexed by y * width + x
        var subtractionArray: [UInt16] = []
        
        do {
            // try to load the image subtraction from a pre-processed file
            subtractionArray = try await PixelatedImage.loadUInt16Array(from: alignedSubtractedFilename)
            Log.d("frame \(frameIndex) loaded outlier amounts from subtraction image")
        } catch {
            Log.i("frame \(frameIndex) couldn't load outlier amounts from subtraction image")
            // do the image subtraction ourselves as a backup
            subtractionArray = try await self.subtractAlignedImageFromFrame()
        }

        self.state = .detectingOutliers1
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

        /*
         make the minimum group size dependent upon the resolution of the sequence

         20 works good for no clouds on 12mp (4240 × 2832)
         20 with clouds on 33 mp is thousands of extra groups

         compute as:

         let minGoupSize = c*b/a

         where a = 12 megapixels,
               b = number of pixels in the sequence being processed
               c = 20, // still a param from outside
         */
        let twelveMegapixels: Double = 4240 * 2832
        let sequenceResolution = Double(width) * Double(height)
        let minGroupSize = Int(Double(config.minGroupSize)*sequenceResolution/twelveMegapixels)

        // one dimentional array mirroring pixels indexed by y*width + x
        var outlierGroupList = [String?](repeating: nil, count: width*height)

        Log.d("using minGroupSize \(minGroupSize)")
        
        // then label all adject outliers
        for (index, outlierAmount) in subtractionArray.enumerated() {
            
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
//                if loopCount % 1000 == 0 {
//                    Log.v("frame \(frameIndex) looping \(loopCount) times groupSize \(groupSize)")
//                }
                
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
                        let leftNeighborAmount = subtractionArray[leftNeighborIndex]
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
                        let rightNeighborAmount = subtractionArray[rightNeighborIndex]
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
                        let topNeighborAmount = subtractionArray[topNeighborIndex]
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
                        let bottomNeighborAmount = subtractionArray[bottomNeighborIndex]
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


            
            if groupSize > minGroupSize { 
                individualGroupCounts[outlierKey] = groupSize
            }
        }

        self.state = .detectingOutliers2

        Log.i("frame \(frameIndex) calculating outlier group bounds")
        var groupInfo: [String:OutlierGroupInfo] = [:] // keyed by group name
        
        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height {
                let index = y*width+x
                if let group = outlierGroupList[index] {
                    let amount = UInt(subtractionArray[index])
                    if let info = groupInfo[group] {
                        info.process(x: x, y: y, amount: amount)
                    } else {
                        let info = OutlierGroupInfo()
                        groupInfo[group] = info
                        info.process(x: x, y: y, amount: amount)
                    }
                }
            }
        }

        self.state = .detectingOutliers3
        // populate the outlierGroups
        for (groupName, groupSize) in individualGroupCounts {
            if let info = groupInfo[groupName],
               let minX = info.minX,
               let minY = info.minY,
               let maxX = info.maxX,
               let maxY = info.maxY
            {
                let groupAmount = info.amount
                let boundingBox = BoundingBox(min: Coord(x: minX, y: minY),
                                              max: Coord(x: maxX, y: maxY))
                let groupBrightness = groupAmount / groupSize

                if let ignoreLowerPixels = config.ignoreLowerPixels,
                   Int(IMAGE_HEIGHT!) - minY <= ignoreLowerPixels
                {
                    Log.v("discarding outlier group with minY \(minY)")
                    continue
                }
                // next collect the amounts

                var maxDiff: UInt16 = 0
                
                var outlierAmounts = [UInt16](repeating: 0, count: boundingBox.width*boundingBox.height)
                for x in minX ... maxX {
                    for y in minY ... maxY {
                        let index = y * self.width + x
                        if let pixelGroupName = outlierGroupList[index],
                           pixelGroupName == groupName
                        {
                            let pixelAmount = subtractionArray[index]
                            let idx = (y-minY) * boundingBox.width + (x-minX)
                            outlierAmounts[idx] = pixelAmount
                            if pixelAmount > maxDiff { maxDiff = pixelAmount }
                        }
                    }
                }

                if maxDiff >= config.maxPixelDistance {
                    let newOutlier = await OutlierGroup(name: groupName,
                                                        size: groupSize,
                                                        brightness: groupBrightness,
                                                        bounds: boundingBox,
                                                        frame: self,
                                                        pixels: outlierAmounts,
                                                        maxPixelDistance: config.maxPixelDistance)
                    outlierGroups?.members[groupName] = newOutlier
                } else {
                    Log.i("skipping frame with maxDiff \(maxDiff) < max \(config.maxPixelDistance)")
                }
            }
        }

        self.state = .readyForInterFrameProcessing
        Log.i("frame \(frameIndex) has found \(String(describing: outlierGroups?.members.count)) outlier groups to consider")
    }

    private func saveSubtractionImage(_ subtractionArray: [UInt16]) throws {
        // XXX make new state for this?
        let imageData = subtractionArray.withUnsafeBufferPointer { Data(buffer: $0)  }

        // write out the subtractionArray here as an image
        let outlierAmountImage = PixelatedImage(width: width,
                                                height: height,
                                                rawImageData: imageData,
                                                bitsPerPixel: 16,
                                                bytesPerRow: 2*width,
                                                bitsPerComponent: 16,
                                                bytesPerPixel: 2,
                                                bitmapInfo: .byteOrder16Little, 
                                                pixelOffset: 0,
                                                colorSpace: CGColorSpaceCreateDeviceGray(),
                                                ciFormat: .L16)
        try outlierAmountImage.writeTIFFEncoding(toFilename: alignedSubtractedFilename)
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
                                    otherFrame: PixelatedImage) async throws
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
                                          otherFrame: otherFrame)
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
                       otherFrame: PixelatedImage)
    {
        var paintPixel = otherFrame.readPixel(atX: x, andY: y)

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
        Log.d("frame \(self.frameIndex) starting to finish")

        self.state = .writingBinaryOutliers

        // write out the outliers binary if it is not there
        // only overwrite the paint reason if it is there
        await self.writeOutliersBinary()
            
        self.state = .writingOutlierValues

        Log.d("frame \(self.frameIndex) finish 1")
        // write out the classifier feature data for this data point
        // XXX THIS MOFO IS SLOW
        try await self.writeOutlierValuesCSV()
            
        Log.d("frame \(self.frameIndex) finish 2")
        if !self.writeOutputFiles {
            self.state = .complete
            Log.d("frame \(self.frameIndex) not writing output files")
            return
        }
        
        self.state = .reloadingImages
        
        Log.i("frame \(self.frameIndex) finishing")
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()
        
        self.writeUprocessedPreviews(image)
        

        // use star aligned image
        let otherFrame = try await imageSequence.getImage(withName: starAlignedSequenceFilename).image()

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
                                          otherFrame: otherFrame)
        
        Log.d("frame \(self.frameIndex) writing output files")
        self.state = .writingOutputFile
        
        Log.d("frame \(self.frameIndex) writing processed preview")
        self.writeProcssedPreview(image, with: outputData)

        Log.d("frame \(self.frameIndex) writing full processed frame")
        // write frame out as a tiff file after processing it
        try image.writeTIFFEncoding(ofData: outputData,  toFilename: self.outputFilename)
        self.state = .complete
        
        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }    
}


fileprivate let fileManager = FileManager.default
