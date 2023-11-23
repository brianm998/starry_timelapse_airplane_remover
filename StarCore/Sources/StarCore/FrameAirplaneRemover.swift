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
    case subtractingNeighbor
    case detectingOutliers1
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

    var message: String {
        switch self {
        case .unprocessed:
            return ""
        case .starAlignment:
            return "aligning stars"
        case .loadingImages:
            return"loading images"
        case .subtractingNeighbor:
            return "subtracting aligned neighbor frame"
        case .detectingOutliers1:
            return "detecting blobs"
        case .detectingOutliers3:
            return "populating outlier groups"
        case .readyForInterFrameProcessing: // XXX not covered in progress monitor
            return "ready for inter frame processing"
        case .interFrameProcessing:
            return "classifing outlier groups"
        case .outlierProcessingComplete:
            return "ready to finish"
        case .writingBinaryOutliers:
            return "writing raw outlier data"
        case .writingOutlierValues:
            return "writing outlier classification values"
        case .reloadingImages:
            return "reloadingImages"
        case .painting:
            return "painting"
        case .writingOutputFile:
            return "frames writing to disk"
        case .complete:
            return "frames complete"
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
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }
    
    func set(state: FrameProcessingState) { self.state = state }
    
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public let bytesPerRow: Int
    public let frameIndex: Int

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

    public let validationImageDirname: String
    public var validationImageFilename: String {
        "\(validationImageDirname)/\(baseName)"
    }

    public let alignedSubtractedPreviewDirname: String
    public var alignedSubtractedPreviewFilename: String {
        "\(alignedSubtractedPreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
    }
    
    public let validationImagePreviewDirname: String
    public var validationImagePreviewFilename: String {
        "\(validationImagePreviewDirname)/\(baseName).jpg" // XXX tiff.jpg :(
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
    
    public let outputFilename: String

    public let imageSequence: ImageSequence

    public let config: Config
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    private var outliersLoadedFromFile = false

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
            do {
                let (_, validationArr) =
                  try await PixelatedImage.loadUInt8Array(from: self.validationImageFilename)
                
                classifyOutliers(with: validationArr)
                shouldUseDecisionTree = false
            } catch {
                Log.i("can't load validation image: \(error)")
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
    
    public var previewFilename: String? {
        if let previewOutputDirname = previewOutputDirname {
            return "\(previewOutputDirname)/\(baseName).jpg" // XXX this makes it .tif.jpg
        }
        return nil
    }
    
    public var processedPreviewFilename: String? {
        if let processedPreviewOutputDirname = processedPreviewOutputDirname {
            return "\(processedPreviewOutputDirname)/\(baseName).jpg"
        }
        return nil
    }
    
    public var thumbnailFilename: String? {
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
         alignedSubtractedPreviewDirname: String,
         validationImageDirname: String,
         validationImagePreviewDirname: String,
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
        self.alignedSubtractedPreviewDirname = alignedSubtractedPreviewDirname
        self.validationImageDirname = validationImageDirname
        self.validationImagePreviewDirname = validationImagePreviewDirname
        
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

        let alignmentFilename = otherFilename
        
        _ = StarAlignment.align(alignmentFilename,
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

                // perhaps apply validation image to outliers here if possible
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

    // returns a grayscale image pixel value array from subtracting the aligned frame
    // from the frame being processed.
    private func subtractAlignedImageFromFrame() async throws -> [UInt16] {
        self.state = .loadingImages
        
        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // use star aligned image
        let otherFrame = try await imageSequence.getImage(withName: starAlignedSequenceFilename).image()

        self.state = .subtractingNeighbor
        
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        Log.i("frame \(frameIndex) finding outliers")

        // the grayscale image pixel array to return when we've calculated it
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
                let subtractionImage = try save16BitMonoImageData(subtractionArray,
                                                                  to: alignedSubtractedFilename)
                Log.d("frame \(frameIndex) saved subtraction image")
                try writeSubtractionPreview(subtractionImage)
                Log.d("frame \(frameIndex) saved subtraction image preview")
            } catch {
                Log.e("can't write subtraction image: \(error)")
            }
        }
        
        return subtractionArray
    }

    func findOutliers() async throws {

        Log.d("frame \(frameIndex) finding outliers)")

        // contains the difference in brightness between the frame being processed
        // and its aligned neighbor frame.  Indexed by y * width + x
        var subtractionArray: [UInt16] = []
        
        self.state = .loadingImages
        do {
            // try to load the image subtraction from a pre-processed file

            let (image, array) = try await PixelatedImage.loadUInt16Array(from: alignedSubtractedFilename)
            subtractionArray = array
            
            Log.d("frame \(frameIndex) loaded outlier amounts from subtraction image")

            try writeSubtractionPreview(image)
        } catch {
            Log.i("frame \(frameIndex) couldn't load outlier amounts from subtraction image")
            // do the image subtraction here instead
            subtractionArray = try await self.subtractAlignedImageFromFrame()
        }

        self.state = .detectingOutliers1

        let blobber = Blobber(imageWidth: width,
                              imageHeight: height,
                              pixelData: subtractionArray,
                              neighborType: .eight,//.fourCardinal,
                              minimumBlobSize: config.minGroupSize,
                              minimumLocalMaximum: config.maxPixelDistance,
                              contrastMin: 58)      // XXX constant

        self.state = .detectingOutliers3

        var minBlobIntensity = UInt16.max
        var maxBlobIntensity: UInt16 = 0

        var blobIntensities: [UInt16] = []

        var allBlobIntensities: UInt32 = 0
        
        for blob in blobber.blobs {
            let blobIntensity = blob.intensity

            blobIntensities.append(blobIntensity)
            allBlobIntensities += UInt32(blobIntensity)
            
            if blobIntensity < minBlobIntensity { minBlobIntensity = blobIntensity }
            if blobIntensity > maxBlobIntensity { maxBlobIntensity = blobIntensity }

            let outlierGroup = blob.outlierGroup(at: frameIndex)
            outlierGroup.frame = self
            outlierGroups?.members[outlierGroup.name] = outlierGroup
        }

        blobIntensities.sort { $0 < $1 }

        if blobber.blobs.count > 0 {
            let mean = allBlobIntensities / UInt32(blobber.blobs.count)
            let median = blobIntensities[blobIntensities.count/2]
            Log.i("frame \(frameIndex) had blob intensity from \(minBlobIntensity) to \(maxBlobIntensity) mean \(mean) median \(median)")
        }
        
        self.state = .readyForInterFrameProcessing
    }
    
    public func pixelatedImage() async throws -> PixelatedImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image()
    }

    public func baseImage() async throws -> NSImage? {
        let name = imageSequence.filenames[frameIndex]
        return try await imageSequence.getImage(withName: name).image().baseImage
    }

    public func baseSubtractedImage() async throws -> NSImage? {
        let name = self.alignedSubtractedFilename
        return try await imageSequence.getImage(withName: name).image().baseImage
    }

    public func baseValidationImage() async throws -> NSImage? {
        let name = self.validationImageFilename
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
        await imageSequence.removeValue(forKey: self.outputFilename)
        Log.d("frame \(frameIndex) purged output files")
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
        self.writeProcessedPreview(image, with: outputData)

        self.writeValidationImage()

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

