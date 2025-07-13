import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa
import Combine

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

public enum FrameSavingState: Sendable {
    case notSaving
    case inPurgatory
    case savePending
    case saving
}

public let finalMonitor = FileSystemMonitor(max: 32)

public let classificationTimingDataHolder = ClassificationTimingDataHolder()

public actor ClassificationTimingDataHolder {
    private var featureTime: TimeInterval = 0
    private var classificationTime: TimeInterval = 0
    private var outlierCount = 0
    private var frameCount = 0
    
    private var callback: ((TimeInterval,TimeInterval,Int,Int) -> Void)?
    
    public func setCallback(_ callback: (@Sendable (TimeInterval,TimeInterval,Int,Int) -> Void)?) {
        self.callback = callback
    }

    public func set(featureTime: TimeInterval,
                    classificationTime: TimeInterval,
                    outlierCount: Int)
    {
        self.featureTime += featureTime
        self.classificationTime += classificationTime
        self.outlierCount += outlierCount
        self.frameCount += 1
        callback?(featureTime, classificationTime, outlierCount, frameCount)
    }
}

@MainActor
@Observable
public class FrameObserver {
    public init() { }

    public var numberOfPositiveOutliers: Int? 
    public var numberOfNegativeOutliers: Int? 
    public var numberOfUndecidedOutliers: Int?
    public var numberOfTrashOutliers: Int?

    // XXX stick more here, like state
    
    public func set(numberOfPositiveOutliers: Int) {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
    }

    public func set(numberOfNegativeOutliers: Int) {
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
    }

    public func set(numberOfUndecidedOutliers: Int) {
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
    }

    public func set(numberOfTrashOutliers: Int) {
        self.numberOfTrashOutliers = numberOfTrashOutliers
    }
    
    func set(numberOfPositiveOutliers: Int,
             numberOfNegativeOutliers: Int,
             numberOfUndecidedOutliers: Int,
             numberOfTrashOutliers: Int)
    {
        self.numberOfPositiveOutliers = numberOfPositiveOutliers
        self.numberOfNegativeOutliers = numberOfNegativeOutliers
        self.numberOfUndecidedOutliers = numberOfUndecidedOutliers
        self.numberOfTrashOutliers = numberOfTrashOutliers
    }
}

final public actor FrameAirplaneRemover: Equatable, Hashable {

    fileprivate var frameSavingState: FrameSavingState = .notSaving {
        didSet {
            if let frameSavingStateChangeCallback = self.callbacks.frameSavingStateChangeCallback {
                frameSavingStateChangeCallback(self, oldValue, frameSavingState)
            }
        }
    }
    
    fileprivate var state: FrameProcessingState = .unprocessed {
        didSet {
            if let frameStateChangeCallback = self.callbacks.frameStateChangeCallback {
                frameStateChangeCallback(self, state)
            }
        }
    }

    public weak var observer: FrameObserver?

    public func set(observer: FrameObserver) {
        self.observer = observer
    }
    
    public func set(state: FrameProcessingState) {
        Log.i("frame \(frameIndex) transitioning to state \(state)")
        self.state = state
    }
    
    public func set(frameSavingState: FrameSavingState) {
        Log.i("frame \(frameIndex) transitioning to saving state \(frameSavingState)")
        self.frameSavingState = frameSavingState
    }
    
    public func processingState() -> FrameProcessingState { return state }

    public func savingState() -> FrameSavingState { return frameSavingState } 
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(frameIndex)
    }

    public func hashValue() async -> Int {
        var hasher = Hasher()
        await self.asyncHash(into: &hasher)
        return hasher.finalize()
    }
    
    public func asyncHash(into hasher: inout Hasher) async {
        self.hash(into: &hasher)

        hasher.combine(self.state)
        
        if let outlierGroups {
            await outlierGroups.asyncHash(into: &hasher)
        }
    }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    nonisolated public let bytesPerPixel: Int
    nonisolated public let bytesPerRow: Int
    nonisolated public let frameIndex: Int

    // populated by pruning
    public var outlierGroups: OutlierGroups? 

    public func getOutlierGroups() -> OutlierGroups?  { outlierGroups }
    
    public func changesHandled() { self.state = .complete }

    public func updateCombineSubjects() async {
        if let outliers = await outlierGroups?.getMembers() {
            var totalPositive: Int = 0
            var totalNegative: Int = 0
            var totalUnknown: Int = 0
            for (_, group) in outliers {
                if let shouldRemove = await group.shouldRemove() {
                    if shouldRemove.willRemove {
                        totalPositive += 1
                    } else {
                        totalNegative += 1
                    }
                } else {
                    totalUnknown += 1
                }
            }

            let trashCount = await outlierGroups?.getTrash().count ?? 0
            
            // update the observer here
            await observer?.set(numberOfPositiveOutliers: totalPositive,
                                numberOfNegativeOutliers: totalNegative,
                                numberOfUndecidedOutliers: totalUnknown,
                                numberOfTrashOutliers: trashCount)
        }
    }

    private var saveTimerTask: Task<Void,Never>?
    
    public func startSaveTimerTask(waitTime: TimeInterval = 12,
                                   closure: @Sendable @escaping () async throws -> Void)
    {
        if let saveTimerTask { saveTimerTask.cancel() }

        saveTimerTask = Task {
          do {
            try? await Task.sleep(nanoseconds: UInt64(waitTime*1_000_000_000))
            try Task.checkCancellation()
            try await closure()
          } catch {
            Log.e("error: \(error)")
          }
          saveTimerTask = nil
        }
    }
    
    // when this happens, re-calculate and send to all the combine subjects
    public func markAsChanged() async {

        // cancel the save timer,
        // whatever process modified this frame can stick it back in purgatory
        if let saveTimerTask { saveTimerTask.cancel() }
        
        //Log.d("mark as changed")
        self.state = .userModified
        //Task { await self.updateCombineSubjects() }
        await self.updateCombineSubjects()
    }

    public func hasChanges() -> Bool { self.state == .userModified }

    public let outputFilename: String

    public let configManager: ConfigManager
    public let callbacks: Callbacks

    public let baseName: String

    // did we load our outliers from a file?
    internal var outliersLoadedFromFile = false

    // doubly linked list
    public weak var previousFrame: FrameAirplaneRemover?
    public weak var nextFrame: FrameAirplaneRemover?

    func getPreviousFrame() -> FrameAirplaneRemover? { previousFrame }
    
    func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }

    func getNextFrame() -> FrameAirplaneRemover? { nextFrame }
    
    func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }
    
    let fullyProcess: Bool

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool

    nonisolated public let imageAccessor: ImageAccessor

    private let completion: (() async -> Void)?
    
    internal var isLoadingOutliers = false

    private weak var imageSequence: ImageSequence?
    
    public init(with configManager: ConfigManager,
                width: Int,
                height: Int,
                bytesPerPixel: Int,
                callbacks: Callbacks,
                imageSequence: ImageSequence,
                atIndex frameIndex: Int,
                outputFilename: String,
                baseName: String,       // source filename without path
                fullyProcess: Bool = true,
                writeOutputFiles: Bool = true,
                imageAccessor: ImageAccessor,
                completion: (@Sendable () async -> Void)? = nil) async throws
    {
        self.imageSequence = imageSequence
        self.imageAccessor = imageAccessor
        self.fullyProcess = fullyProcess
        self.writeOutputFiles = writeOutputFiles
        self.configManager = configManager
        self.baseName = baseName
        self.callbacks = callbacks
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename
        self.completion = completion
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

        // call directly in init becuase didSet() isn't called from here :P
       
        self.baseFilename = imageSequence.filenames[frameIndex]

        let config = await configManager.config()
        setNumberOfAlignmentImages(config.numberAlignedNeighborFrames)
        
        if imageAccessor.imageExists(frameIndex: frameIndex,
                                     ofType: .processed,
                                     atSize: .original)
        {
            self.state = .complete
        } else if FileManager.default.fileExists(atPath: "\(await self.outliersDirname)/\(BlobBinarySaver.outlierBinaryFilename)") {
            // if we have outliers, mark it as userModified (classified),
            // even if some are not classified
            self.state = .userModified
        }
        
        if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, self.state)
        }

        await self.updateCombineSubjects()
    }

    public func setNumberOfAlignmentImages(_ alignmentNumber: Int) {
        guard let imageSequence else {
            Log.e("cannot set number of alignment images without an image sequence")
            return
        }
        if alignmentNumber < 1 {
            Log.e("invalid alignmentNumbernumberOfImage \(alignmentNumber)")
            return
        }

        var halfNumber = alignmentNumber/2
        if alignmentNumber % 2 == 1 { halfNumber += 1 } // round up

        var startFrame: Int = 0
        var endFrame: Int = alignmentNumber + 1
        
        if frameIndex <= halfNumber {
            // this frame is close to the front, keep start and end at the beginning
            
        } else if frameIndex >= imageSequence.filenames.count-1-halfNumber {
            // this frame is close to the end, use the last frame as the end frame

            endFrame = imageSequence.filenames.count
            startFrame = endFrame - alignmentNumber - 1

        } else {
            // this frame is not alignment number close to either end
            // back up the start frame half number from the frame index
            
            startFrame = frameIndex - halfNumber
            endFrame = startFrame + alignmentNumber + 1
        }

        // calculate the frame indicies of the frames we will use for star alignment
        for index in startFrame..<endFrame {
            if index == frameIndex { continue }
            alignmentFrames.append(index)
        }

        Log.d("frame \(frameIndex) has alignment frames \(alignmentFrames)")
    }

    public var numberOfAlignedFrames: Int { alignmentFrames.count }
    
    
    private func loadOrCreateStarAlignedImages() async throws  -> [Int:PixelatedImage] {
        var alignedImages = try await loadStarAlignedImages()

        if alignedImages.count != numberOfAlignedFrames {

            // get rid of any existing files
            if let dirname = imageAccessor.dirForImage(ofType: .aligned,
                                                       atSize: .original)
            {
                try removeAllFiles(in: "\(dirname)/\(frameIndex)")
            }
            
            // try creating the star aligned images if we couldn't load them
            Log.i("doing star alignment at finish")
            alignedImages = try await starAlignedImages()
        }
        return alignedImages
    }
    
    private var alignmentFrames: [Int] = []
    private let baseFilename: String

    // the filenames of the original files that we should align with this frame
    private var alignmentFilenames: [Int:String] {
        guard let imageSequence else {
            Log.e("cannot get alignemnt frames images without an image sequence")
            return [:]
        }
        var ret: [Int:String] = [:]
        for alignmentFrame in alignmentFrames {
            ret[alignmentFrame] = imageSequence.filenames[alignmentFrame]
        }
        return ret
    }
    
    internal var userSlices: [BoundingBox]? = nil

    public func getUserSlices() async -> [BoundingBox] {
        if let userSlices { return userSlices }

        await self.loadUserSlices()

        if let userSlices { return userSlices }

        return []               // doh!
        
    }

    public var userSliceDirname: String {
        get async {
            let config = await configManager.config()
            return "\(config.outputPath)/\(config.imageSequenceDirname)-star-user-slices"
        }
    }

    public var userSliceFilename: String {
        get async {
            let dirname = await self.userSliceDirname
            return "\(dirname)/slices_\(frameIndex).json"
        }
    }

    private func loadStarAlignedImages() async throws -> [Int: PixelatedImage] {
        guard let imageSequence else {
            let error = "cannot load star aligned images with no image sequence"
            Log.e(error)
            throw error
        }
        var alignedImages: [Int: PixelatedImage] = [:]


        if let dirname = imageAccessor.dirForImage(ofType: .aligned,
                                                   atSize: .original)
        {
            let dirname = "\(dirname)/\(frameIndex)"
            
            for alignmentFrameIndex in alignmentFrames {
                if alignmentFrameIndex != frameIndex {

                    // XXX this is wrong :(

                    let origFullPath = imageSequence.filenames[alignmentFrameIndex]
                    if let origFilename = origFullPath.substringAfterLastSlash() {
                        
                        let alignedFilename = "\(dirname)/\(origFilename)"
                        
                        if FileManager.default.fileExists(atPath: alignedFilename) {
                            Log.d("file exists at \(alignedFilename)")
                            let alignedFrame = try await imageSequence.getImage(withName: alignedFilename).image()
                            alignedImages[alignmentFrameIndex] = alignedFrame
                        }
                    }
                }
            }
        }

        Log.d("loaded \(alignedImages.count) aligned images")
        
        return alignedImages
    }
    
    // lazy loaded aligned a neighboring frame
    public func starAlignedImages() async throws -> [Int: PixelatedImage] {
        guard let imageSequence else {
            let error = "cannot align star images without an image sequence"
            Log.e(error)
            throw error
        }
        let alignedImageMap = try await loadStarAlignedImages()

        if alignedImageMap.count > 0 { return alignedImageMap }
        
        // create the aligned images if not found
        Log.d("frame \(frameIndex) creating aligned frame")
        if let dirname = imageAccessor.dirForImage(ofType: .aligned,
                                                   atSize: .original)
        {
            let dirname = "\(dirname)/\(frameIndex)"
            StarCore.mkdir(dirname)
            Log.d("frame \(frameIndex) creating aligned frame in \(dirname)")
            self.set(state: .starAlignment)

            // call directly in init becuase didSet() isn't called from here :P
            //                if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            //                    frameStateChangeCallback(self, self.state)
            //                }
            Log.d("frame \(frameIndex) alignedFilename start")
            
            let alignedFilenames = try await StarAlignment.align(alignmentFilenames,
                                                                 to: baseFilename,
                                                                 inDir: dirname)

            var ret: [Int:PixelatedImage] = [:]

            for (index, alignedFilename) in alignedFilenames {

                Log.d("frame \(frameIndex) alignedFilename \(String(describing: alignedFilename))")

                Log.d("frame \(frameIndex) got aligned filename \(alignedFilename)")

                if FileManager.default.fileExists(atPath: alignedFilename) {
                    let alignedFrame = try await imageSequence.getImage(withName: alignedFilename).image()
                    
                    // XXX maybe not preview all aligned images anymore?
                    /*
                     try await imageAccessor.save(alignedFrame,
                     frameIndex: frameIndex,
                     as: .aligned,
                     atSize: .preview,
                     overwrite: false)
                     */
                    ret[index] = alignedFrame
                } else {
                    // XXX this isn't handled well
                    Log.e("frame \(frameIndex) could not load aligned frame")
                }

            }
            return ret
        } else {
            Log.w("frame \(frameIndex) no dirname for aligned original images")
        }

        return [:]
    }
    
    public func setupOutliers() async throws {
        // this takes a long time, and the gui does it later
        try await loadOutliers()
    }

    // run after shouldRemove has been set for each group, 
    // does the final removing and then writes out the output files
    public func finish() async throws {
        Log.d("frame \(self.frameIndex) starting to finish")
        
        mkdir(await self.outliersDirname)
        
        await self.writeOutliersRemoveReasons()

        self.set(state: .finishing)

        let config = await configManager.config()
        
        if config.writeOutlierClassificationValues {
            // THIS MOFO IS SLOW
            self.set(state: .writingOutlierValues)

            Log.d("frame \(self.frameIndex) finish 1")
            // write out the classifier feature data for this data point
            try await self.writeOutlierValuesCSV()
        }

        Log.d("frame \(self.frameIndex) finish 2")
        if !self.writeOutputFiles {
            Log.d("frame \(self.frameIndex) not writing output files")
            self.set(state: .complete)
            if let completion { await completion() }
            return
        }
        
        Log.i("frame \(self.frameIndex) finishing")

        self.set(state: .waitingToLoadImages)
        let fi = self.frameIndex
        let ia = self.imageAccessor
        let image = try await finalMonitor.load() { [weak self] in
            //guard let self else { return }
            await self?.set(state: .loadingImages)
            return await (ia.loadInt(frameIndex: fi,
                                                type: .original,
                                                atSize: .original))
        }

        guard let image = image
        else { throw "couldn't load original file for finishing" }
        
        if self.writeOutputFiles {
            self.set(state: .loadingImages1)
            try await imageAccessor.saveFinal(image, 
                                              frameIndex: frameIndex,
                                              as: .original,
                                              atSize: .preview,
                                              overwrite: false)
            try await imageAccessor.saveFinal(image,
                                              frameIndex: frameIndex,
                                              as: .original,
                                              atSize: .thumbnail,
                                              overwrite: false)
        }

        let alignedImages = try await loadOrCreateStarAlignedImages()

        guard alignedImages.count != 0 else {
            throw "couldn't load aligned file for finishing"
        }
        
        let format = image.imageData // make a copy

        switch format {
        case .thirtyTwoBit(_):
            fatalError("frame \(self.frameIndex) cannot load 32 bit image here now")
                
        case .eightBit(_):
            Log.e("8 bit not supported here now")
        case .sixteenBit(var outputData):
            Log.d("frame \(self.frameIndex) removing over airplanes")

            try await self.removeAirplanes(image: image,
                                           toData: &outputData,
                                           alignedImages: alignedImages)

            Log.d("frame \(self.frameIndex) writing output files")
            self.set(state: .writingOutputFile)

            Log.d("frame \(self.frameIndex) updating image")
            let processedImage = image.updated(with: outputData)
            // write frame out as processed versions
            do {
                Log.d("frame \(self.frameIndex) processed file")
                try await imageAccessor.saveFinal(processedImage,
                                                  frameIndex: frameIndex,
                                                  as: .processed,
                                                  atSize: .original,
                                                  overwrite: true)
                Log.d("frame \(self.frameIndex) writing processed preview")
                try await imageAccessor.saveFinal(processedImage,
                                                  frameIndex: frameIndex,
                                                  as: .processed,
                                                  atSize: .preview, overwrite: true)
            } catch {
                // XXX for some reason this error gets missed if we don't catch it here :(
                Log.d("frame \(self.frameIndex) ERROR \(error)")

            }
            if let outlierGroups {
                Log.d("frame \(self.frameIndex) getting validating image")
                let validationImage = await outlierGroups.validationImage()
                Log.d("frame \(self.frameIndex) writing validated image")
                try await imageAccessor.saveFinal(validationImage,
                                                  frameIndex: frameIndex,
                                                  as: .validation,
                                                  atSize: .original,
                                                  overwrite: false)
                Log.d("frame \(self.frameIndex) writing validated preview")
                try await imageAccessor.saveFinal(validationImage,
                                                  frameIndex: frameIndex,
                                                  as: .validation,
                                                  atSize: .preview,
                                                  overwrite: false)
            }
            Log.d("frame \(self.frameIndex) done writing output files")
        }
        self.set(state: .complete)
        if let completion { await completion() }
        
        Log.i("frame \(self.frameIndex) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }

    // Mark - Outliers
    

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

    public var blobBinaryFilename: String { 
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)/\(BlobBinarySaver.outlierBinaryFilename)"
        }
    }
    
    public var trashBinaryFilename: String { 
        get async {
            let config = await configManager.config()
            return "\(config.outlierOutputDirname)/\(frameIndex)/\(BlobBinarySaver.trashBinaryFilename)"
        }
    }
    
    public func loadOutliersFromBinaryFile() async throws -> OutlierGroups? {
        let config = await configManager.config()
        let dirname = "\(config.outlierOutputDirname)/\(frameIndex)"

        return try await OutlierGroups(at: frameIndex, fromOutlierDir: dirname)
    }
    
    // re-runs outlier detection within bounds with current settings
    public func findOutliers(within bounds: BoundingBox) async throws {
        Log.d("shovel frame \(frameIndex) finding outliers within bounds \(bounds)")
        mkdir(await self.outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor
        
        let newBlobMap = try await blobProcessor.process(frame: self, within: bounds)

        // add new blobs to outlier groups, fore-going any classification for now
        await outlierGroups?.add(blobs: newBlobMap, within: bounds)

        try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)
        Log.d("shovel frame \(frameIndex) done finding outliers within bounds \(bounds)")
    }
    
    public func findOutliers() async throws {
        
        mkdir(await self.outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor
        
        let blobMap = try await blobProcessor.process(frame: self)

        // blobs to promote to outlier groups
        let blobs = Array(blobMap.values)

        Log.i("frame \(frameIndex) has \(blobs.count) blobs")
        self.set(state: .firstClassification)

        let classifier = OutlierClassifier(frame: self)

        let trashLevel = await constants.getTrashLevel()

        // this changes based upon Y value
        let smallTrashMax = await constants.getSmallTrashMax()
        
        let (good, bad, featureTime, classificationTime, outlierCount) =
          await classifier.promoteAndClassify(blobs,
                                              trashLevel: trashLevel,
                                              smallTrashMax: smallTrashMax)
        Task {
            await classificationTimingDataHolder.set(featureTime: featureTime,
                                                     classificationTime: classificationTime,
                                                     outlierCount: outlierCount)
        }
        
        // XXX promote featureTime and classificationTime to the gui
        
        await self.outlierGroups?.add(good)
        await self.outlierGroups?.dumpInTrash(bad)
        
        // here we write the outlier binaries through the outlierGroups
        try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)

        // XXX update UI
        
        self.set(state: .readyForInterFrameProcessing)
    }

    public func loadOutliers(loadOnly: Bool = false) async throws {
        if isLoadingOutliers {
            Log.w("Not loading twice")
            return
        }
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
    
    public func foreachOutlierGroup(includingTrash: Bool,
                                    _ closure: @Sendable (OutlierGroup, Bool) async -> Void) async
    {
        if let outlierGroups {
            for (_, group) in await outlierGroups.getMembers() {
                await closure(group, false)
            }
            for (_, group) in await outlierGroups.getTrash() {
                await closure(group, true)
            }
        } 
    }

    public func foreachOutlierGroupMulti(includingTrash: Bool,
                                         _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Void) async
    {
        if let outlierGroups {
            await Task.detached(priority: .userInitiated) {

                let outliers = await Array(outlierGroups.getMembers().values)
                var trash: [OutlierGroup] = []

                if includingTrash {
                    trash = await Array(outlierGroups.getTrash().values)
                }
                await foreachOutlier(in: outliers, with: trash, closure)
            }.value
        } 
    }

    public func outlierGroup(named outlierName: UInt16) async -> OutlierGroup? {
        await outlierGroups?.getMembers()[outlierName]
    }

    public func foreachOutlierGroupMulti(between startLocation: CGPoint,
                                         and endLocation: CGPoint,
                                         includingTrash: Bool, 
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
        
        await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change removal status
                await closure(group, isInTrash)
            }
        }
    }

    public func maybeApplyOutlierGroupClassifier(includingTrash: Bool) async throws {

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
            case .thirtyTwoBit(_):
                fatalError("frame \(frameIndex) cannot load 32 bit validation image")
                
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
            self.set(state: .secondClassification)
            await self.applyDecisionTreeToAllOutliers(includingTrash: includingTrash)
        }
    }

    // used to classify outliers given a validation image.
    // this validation image contains a non zero pixel for each outlier
    // that should be removed.
    // any outlier that matches any pixels is classified to remove here.
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
                //Log.d("group \(group) shouldRemove \(String(describing: group.shouldRemove))")
                await group.shouldRemove(.userSelected(groupIsValid))
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

    public func outlierGroupTrashList() async -> [OutlierGroup]? {
        if let outlierGroups {
            let groups = await outlierGroups.getTrash()
            return groups.map {$0.value}
        } else {
            try? await loadOutliers()
            if let outlierGroups {
                let groups = await outlierGroups.getTrash()
                return groups.map {$0.value}
            } else {
                Log.w("NO GROUPS")
            }
        }
        return nil
    }

    // used for saving different images of blobs
    public func saveImages(for blobs: [Blob], as frameImageType: FrameViewMode) async throws {
        var blobImageData = [UInt8](repeating: 0, count: width*height)
        for blob in blobs {
            for pixel in await blob.getPixels() {
                let imageIntensity = pixel.uInt16Value >> 8
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

    public func applyRazor(in boundingBox: BoundingBox, includingTrash: Bool) async throws {
        /*
         - find all outliers that have some match with this bounding box
         - remove them from outlier groups list
         - convert them to blobs
         - do intersection with bounding box to create new blob
         - convert all of them back to outlier groups
         */

        if await outlierGroups?.applyRazor(in: boundingBox,
                                           includingTrash: includingTrash) ?? false
        {
            await self.markAsChanged()

            try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)

            await updateUserSlices(with: boundingBox)

            await self.updateCombineSubjects()            
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
        await updateCombineSubjects()
        
        try await outlierGroups.writeOutliersBinary(to: self.outliersDirname)

        return ret
    }

    public func deleteOutliers() async throws {
        try await outlierGroups?.removeOutliersBinary(from: self.outliersDirname)
        self.outlierGroups = nil
    }
    
    public func deleteOutliers(in boundingBox: BoundingBox) async throws {
        await outlierGroups?.deleteOutliers(in: boundingBox)

        await self.markAsChanged()
        
        try await outlierGroups?.writeOutliersBinary(to: self.outliersDirname)
        // XXX add y-axis here too
    }

        // Mark - Removal

    /*
     Logic about removing undesired elements from the image.

     Removing is done with data from a neighboring, aligned frame.

     Pixels to be removed come from validated outlier groups,
     that logic is elsewhere.
     */

    // actually remove outlier groups that have been selected as airplane tracks
    internal func removeAirplanes(image: PixelatedImage,
                                  toData data: inout [UInt16],
                                  alignedImages: [Int:PixelatedImage]) async throws
    {
        Log.i("frame \(frameIndex) removing airplane outlier groups")

        // remove every outlier in the list with pixels from the adjecent frames
        guard let outlierGroups = outlierGroups else {
            Log.e("cannot remove pixels without outlier groups")
            return
        }

        guard await outlierGroups.getMembers().count > 0 else {
            Log.v("no outliers, not removing")
            return
        }
        
        self.set(state: .creatingRemovalMask)

        // the alpha level to apply to each pixel in the image
        // indexed by y*width+x
        // this is esentially a layer mask for the frame, 
        // with the adjusted neighbor frame underneath
        var alphaLevels = [Double](repeating: 0, count: width*height)
        var alphaYAxis = [UInt8](repeating: 0, count: height)

        // first go through the outlier groups and determine what alpha
        // level to apply to each pixel in this frame.
        // alpha zero means no removing, keep original pixel
        // alpha one means overwrite original pixel entierly with data from other frame

        let config = await configManager.config()

        // the alpha mask that we will convolve across all removable pixels
        let removeMask = RemoveMask(innerWallSize: config.outlierGroupPaintBorderInnerWallPixels,
                                    radius: config.outlierGroupPaintBorderPixels)
        
        let removeMaskIntRadius = Int(removeMask.radius)

        // only remove when we have found at least one positive outlier group
        var shouldRemove = false
        
        for (_, group) in await outlierGroups.getMembers() {
            if let reason = await group.shouldRemove(),
               reason.willRemove
            {
                shouldRemove = true
                //Log.d("frame \(frameIndex) removing over group \(group) for reason \(reason)")

                for pixel in group.pixelSet {
                    // start in frame coords
                    let maskStartX = pixel.x - removeMaskIntRadius
                    let maskStartY = pixel.y - removeMaskIntRadius

                    for maskX in 0..<removeMask.size {
                        for maskY in 0..<removeMask.size {
                            let frameX = maskX + maskStartX
                            let frameY = maskY + maskStartY

                            if frameX >= 0,
                               frameX < width,
                               frameY >= 0,
                               frameY < height
                            {
                                let frameIndex = frameY*width+frameX
                                let maskIndex = maskY*removeMask.size+maskX
                                
                                let frameAlpha = alphaLevels[frameIndex]
                                let maskAlpha = removeMask.pixels[maskIndex]
                                if maskAlpha > frameAlpha {
                                    alphaLevels[frameIndex] = maskAlpha
                                    alphaYAxis[frameY] = 0xFF
                                }
                            }
                        }
                    }
                }
            }
        }

        if config.writeOutlierGroupFiles { // XXX this config value is very much overloaded
            var removeMaskImageData = [UInt8](repeating: 0, count: width*height)

            for y in 0 ..< height {
                if alphaYAxis[y] == 0 { continue }
                for x in 0 ..< width {
                    let index = y*width+x
                    let alpha = alphaLevels[index]
                    if alpha > 0 {
                        var value = Int(alpha*Double(0xFF))
                        if value > 0xFF { value = 0xFF }
                        removeMaskImageData[index] = UInt8(value)
                    }
                }
            }

            let removeMaskImage = PixelatedImage(width: width, height: height,
                                                 grayscale8BitImageData: removeMaskImageData)
            let (_,_) = await (try imageAccessor.save(removeMaskImage,
                                                      frameIndex: frameIndex,
                                                      as: .removeMask,
                                                      atSize: .original,
                                                      overwrite: true),
                               try imageAccessor.save(removeMaskImage,
                                                      frameIndex: frameIndex,
                                                      as: .removeMask,
                                                      atSize: .preview,
                                                      overwrite: true))
        }

        if shouldRemove {
            self.set(state: .assemblingProcessedFrame)
            
            // then actually remove each non zero alpha pixel,
            // replacing it with one from another frame
            for y in 0 ..< height {
                if alphaYAxis[y] == 0 { continue }
                for x in 0 ..< width {
                    var alpha = alphaLevels[y*width+x]
                    if alpha > 0 {
                        if alpha > 1 { alpha = 1 }

                        updatePixel(x: x, y: y,
                                    alpha: alpha,
                                    toData: &data,
                                    image: image,
                                    from: alignedImages)

                        /*

                         // test paint the expected alpha levels as colors
                         
                         var paintPixel = Pixel()
                         paintPixel.blue = 0xFFFF
                         paintPixel.green = UInt16(Double(0xFFFF)*alpha)
                         paint(x: x, y: y, why: reason, alpha: alpha,
                         toData: &data,
                         image: image,
                         paintPixel: paintPixel)
                         */

                    }
                }
            }
        }
    }

    // remove a selected outlier pixel with data from pixels from adjecent frames
    // this tries to use fancy logic to ignore bad pixel values

    // XXX this is a waste of time :(

    // it kind of works, but not really that great.
    internal func updatePixel(x: Int, y: Int,
                              alpha: Double,
                              toData data: inout [UInt16],
                              image: PixelatedImage,
                              from alignedImages: [Int:PixelatedImage])
    {
        var newPixels: [Pixel] = []

        for image in alignedImages.values {
        //    let overwritingPixel = image.readPixel(atX: x, andY: y)
   //         if image.componentsPerPixel == 4, // has alpha channel
   //            overwritingPixel.alpha != 0xFFFF   // alpha is not fully opaque
  //          {
  //              // ignore transparent pixels
  //              continue
 //           }
            
            newPixels.append(image.readPixel(atX: x, andY: y))
        }

        // threshold factor 4 is loose
        // threshold factor 3 is regular
        // threshold factor 2.5 is tight

        // 1.0 misses a few :(

        // 2.0 w/ 16 neighbors is almost there, has a small dark ring around the brightest
        // 2.0 w/ 8 neighbors misses a few, a less dark
        // 1.2 w/ 8 neighbors is same as VVV
        // 0.8 w/ 16 neighbors kills all the baddies, but still has a bit of dark
        // 0.5 is really tight
        let goodPixels = newPixels.goodPixels(thresholdFactor: 1.2) // XXX make this a param
/*
        if newPixels.count != goodPixels.count {
            Log.i("frame \(frameIndex) dropped \(newPixels.count - goodPixels.count) pixels out of \(newPixels.count)")
        } else {
            Log.i("frame \(frameIndex) kept all \(goodPixels.count) pixels")
        }
  */      
        if goodPixels.count > 0 {
            self.updatePixel(x: x, y: y,
                             alpha: alpha,
                             toData: &data,
                             image: image,
                             with: Pixel(merging: goodPixels))
        } else {
            Log.w("no good pixels found :(")
        }
    }

    // remove a selected outlier pixel with data from pixels from adjecent frames
    // this just sums them all, ignoring any potential bad signal, hoping to drown it out
    // with lots of other frames
    internal func updatePixelSum(x: Int, y: Int,
                                 alpha: Double,
                                 toData data: inout [UInt16],
                                 image: PixelatedImage,
                                 from alignedImages: [Int:PixelatedImage])
    {
        var newPixels: [Pixel] = []

        for image in alignedImages.values {
            let overwritingPixel = image.readPixel(atX: x, andY: y)
            if image.componentsPerPixel == 4, // has alpha channel
               overwritingPixel.alpha != 0xFFFF   // alpha is not fully opaque
            {
                // ignore transparent pixels
                continue
            }
            
            newPixels.append(image.readPixel(atX: x, andY: y))
        }

        
        self.updatePixel(x: x, y: y,
                         alpha: alpha,
                         toData: &data,
                         image: image,
                         with: Pixel(merging: newPixels))
    }

    // punts by just uses the first aligned image
    internal func updatePixelPunt(x: Int, y: Int,
                                  alpha: Double,
                                  toData data: inout [UInt16],
                                  image: PixelatedImage,
                                  from alignedImages: [Int:PixelatedImage])
    {

        // XXX need much more complex logic here now

        // for now, just grab the first aligned frame
        if let otherFrame = alignedImages.values.first {

            /*
             next step is to compute a new overwriting pixel value from all aligned
             images, ignoring those which are marked as non zero on the removal mask
             for the other frame

             need to update processing to allow for the removal mask to be available here
             */
            
            let overwritingPixel = otherFrame.readPixel(atX: x, andY: y)

            if otherFrame.componentsPerPixel == 4, // has alpha channel
               overwritingPixel.alpha != 0xFFFF   // alpha is not fully opaque
            {
                // ignore transparent pixels
                return
            }

            self.updatePixel(x: x, y: y,
                             alpha: alpha,
                             toData: &data,
                             image: image,
                             with: overwritingPixel)
        } else {
            Log.e("FUCK")
        }
    }


    // remove a selected outlier pixel with data from pixels from adjecent frames
    internal func updatePixel(x: Int, y: Int,
                              alpha: Double,
                              toData data: inout [UInt16],
                              image: PixelatedImage,
                              with overwritingPixel: Pixel)
    {
        var overwritingPixel = overwritingPixel
        let op = image.readPixel(atX: x, andY: y)

        // don't make the original image brighter at this pixel
        // leave the original value there in this case
        if op.intensity < overwritingPixel.intensity { return }
        
        if alpha < 1 {
            // merge in original value
            overwritingPixel = Pixel(merging: overwritingPixel, with: op, atAlpha: alpha)
        }

        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow/2) + (Int(x) * bytesPerPixel/2)

        // actually remove that airplane like thing in the image data
        if self.bytesPerPixel == 2 {
            // one componant per pixel, binary 16 bit image
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [overwritingPixel.red])
        } else if self.bytesPerPixel == 6 {
            // three componants per pixel, RGB 16 bit image
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [overwritingPixel.red,
                                        overwritingPixel.green,
                                        overwritingPixel.blue])

        } else if self.bytesPerPixel == 8 {
            // four componants per pixel, RGBA 16 bit image
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [overwritingPixel.red,
                                        overwritingPixel.green,
                                        overwritingPixel.blue,
                                        0xFFFF]) // always write full opacity
        }
    }

    // Mark - UI

    /*
     UI related methods
     */
    
    public func applyDecisionTreeToAutoSelectedOutliers(includingTrash: Bool,
                                                        overwrite: Bool = false,
                                                        minimumSize: Int? = nil) async {
        if let classifier = await currentClassifier.get(for: .all) {
            await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                if let minimumSize,
                   group.size < minimumSize { return }
                
                var apply = true
                if !overwrite,
                   let shouldRemove = await group.shouldRemove() {
                    switch shouldRemove {
                    case .userSelected(_):
                        // leave user selected ones in place
                        apply = false
                    default:
                        break
                    }
                }
                if apply {
                    Log.d("applying decision tree")
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                        await self.markAsChanged()
                    }
                    await group.shouldRemove(.fromClassifier(await classifier.classification(of: group)))
                }
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches(includingTrash: Bool) async {
        await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, _ in
            await group.clearFeatureValueCache()
        }
    }

    public func applyDecisionTreeToAllOutliers(includingTrash: Bool,
                                                        overwrite: Bool = true,
                                                        minimumSize: Int? = nil) async
    {
      Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(await self.outlierGroups?.members.count ?? 0) Outliers")
        let startTime = NSDate().timeIntervalSince1970
        if let outlierGroups {
            let groups = await outlierGroups.getMembers()
            await Task.detached(priority: .userInitiated) {
                let classifier = OutlierClassifier(frame: self)

                var values = Array(groups.values)

                if let minimumSize {
                    values = values.filter { $0.size > minimumSize }
                }
                
                await classifier.classifyAll(values, overwrite: overwrite)
                let endTime = NSDate().timeIntervalSince1970
                Task { @MainActor in
                    await self.updateCombineSubjects()
                }
                
                Log.i("frame \(self.frameIndex) spent \(endTime - startTime) seconds classifing outlier groups");
            }.value
        } else {
            Log.w("no classifier")
        }
        Log.d("frame \(self.frameIndex) DONE applyDecisionTreeToAllOutliers")
    }
    
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      includingTrash: Bool) async
    {
        await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                if isInTrash {
                    await self.outlierGroups?.promoteFromTrash(group)
                }
                await group.shouldRemove(.userSelected(shouldRemove))
            }
            // 
        }.value
        Task { @MainActor in
            await self.markAsChanged()
            await self.updateCombineSubjects()
        }
    }

    public func userSelectUndecidedOutliers(toShouldRemove shouldRemove: Bool,
                                            includingTrash: Bool) async
    {
        await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                if await group.shouldRemove() == nil {
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                    }
                    await group.shouldRemove(.userSelected(shouldRemove))
                }
            }
        }.value
        Task { @MainActor in
            await self.markAsChanged()
            await self.updateCombineSubjects()
        }
    }

    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      overlapping group: OutlierGroup) async
    {
        guard let outlierGroups else { return }

        for group in await outlierGroups.groups(overlapping: group) {
            await group.shouldRemove(.userSelected(shouldRemove))
        }
        Task { @MainActor in
            await self.markAsChanged()
            await self.updateCombineSubjects()
        }
    }
    
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint,
                                      includingTrash: Bool) async
    {
        await foreachOutlierGroupMulti(between: startLocation,
                                       and: endLocation,
                                       includingTrash: includingTrash) { group, isInTrash in
            if isInTrash {
                await self.outlierGroups?.promoteFromTrash(group)
                await self.markAsChanged()
            }
            await group.shouldRemove(.userSelected(shouldRemove))
        }
        Task { @MainActor in
            await self.markAsChanged()
            await self.updateCombineSubjects()
        }
    }

    // Mark - Subtraction

    /*

     Image subtraction logic
     
     */

    // returns a grayscale image pixel value array from subtracting the aligned frame
    // from the frame being processed.
    internal func subtractAlignedImageFromFrame() async throws -> PixelatedImage {
        // first try to load the subtracted image directly from file

        let accessor = imageAccessor
        
        if let image = try await imageAccessor.load(frameIndex: frameIndex,
                                                    type: .subtraction,
                                                    atSize: .original)
        {
            return image
        }

        // if we don't have the subtracted image on file yet, make it
        Log.d("frame \(frameIndex) subtractAlignedImageFromFrame")


        // load the original
        guard let image = try await accessor.load(frameIndex: frameIndex,
                                                  type: .original,
                                                  atSize: .original)
        else {
            Log.e("frame \(frameIndex) couldn't load original image")
            // XXX these should really throw an error, and that really should
            // be handled properly at a higher level, but right now, thrown errors
            // from here end up in the bitbucket :(  Need to figure out why
            throw "frame \(frameIndex) couldn't original image"
        }
        Log.d("frame \(frameIndex) got orig image")
        
        // load or create the aligned frame

        let alignedImages = try await loadOrCreateStarAlignedImages().values

        guard alignedImages.count > 0 else {
            let error = "frame \(frameIndex) can't load any star aligned images"
            Log.e(error)
            throw error
        }
        
        Log.d("frame \(frameIndex) got \(alignedImages.count) star aligned images")

        let rest = Array(alignedImages.dropFirst())

        guard let first = alignedImages.first else {
            let error = "cannot get first aligned image, cannot subtract image"
            Log.e(error)
            throw error
        }

        Log.d("trying to merge")
        
        let mergedAlignedImage = try first.mergeWith(rest)
        
        self.set(state: .subtractingNeighbor)
        
        Log.i("frame \(frameIndex) finding outliers")

        // subtract them
        // result is image - alignedFrame
        // any pixel which is bright in image but not bright in alignedFrame
        // will be bright in the subtractionImage
        let subtractionImage = image.subtract(mergedAlignedImage)

        let config = await configManager.config()
        
        if config.writeOutlierGroupFiles {
            // write out image of outlier amounts
            do {
                try await accessor.save(subtractionImage,
                                        frameIndex: frameIndex,
                                        as: .subtraction,
                                        atSize: .original,
                                        overwrite: false)
                try await accessor.save(subtractionImage,
                                        frameIndex: frameIndex,
                                        as: .subtraction,
                                        atSize: .preview,
                                        overwrite: false)
            } catch {
                Log.e("frame \(frameIndex) can't write subtraction image: \(error)")
            }
        }

        return subtractionImage
    }

    // Mark - File output

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {
        try await fileSystemMonitor.save() { try await self.writeOutlierValuesCSVInt() }
    }
    
    private func writeOutlierValuesCSVInt() async throws {

        Log.d("frame \(self.frameIndex) writeOutlierValuesCSV")
        let config = await configManager.config()
        
        if config.writeOutlierGroupFiles {
            // write out the decision tree value matrix too
            Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1")

            let frameOutlierDir = "\(config.outlierOutputDirname)/\(self.frameIndex)"
            let csvFilename = "\(frameOutlierDir)/\(CondensedOutlierGroupValueMatrix.outlierDataFilename)"

            await Task.detached(priority: .userInitiated) {
                do {
                    try await writeOutlierValuesCSVPrivate(to: csvFilename,
                                                           frameOutlierDir: frameOutlierDir,
                                                           frame: self)
                } catch {
                    Log.e("frame \(self.frameIndex) unable to write outlier values csv to \(csvFilename)")
                }
            }.value
        }
        Log.d("frame \(self.frameIndex) DONE writeOutlierValuesCSV")
    }

    public func writeOutliersRemoveReasons() async {
        let config = await configManager.config()
        if config.writeOutlierGroupFiles {
            do {
                try await fileSystemMonitor.save() {
                    try await self.outlierGroups?.write(to: config.outlierOutputDirname)
                }
            } catch {
                Log.e("error \(error)")
            }                
        }
    }
}

fileprivate func writeOutlierValuesCSVPrivate(to csvFilename: String,
                                              frameOutlierDir: String,
                                              frame: FrameAirplaneRemover) async throws
{
    // check to see if both of these files exist already
    if FileManager.default.fileExists(atPath: csvFilename) {
        Log.i("frame \(frame.frameIndex) not recalculating outlier values with existing files")
    } else {
        let valueMatrix = await CondensedOutlierGroupValueMatrix(for: frame)

        if let outliers = await frame.outlierGroupList() {
            Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 1a \(outliers.count) outliers")
            let startTime = NSDate().timeIntervalSince1970
            // XXX start time
            
            for (index, outlier) in outliers.enumerated() {
                if index % 100 == 0 {
                    let duration = NSDate().timeIntervalSince1970 - startTime
                    Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 1b \(index) after \(duration) seconds")
                }
                await valueMatrix.append(outlierGroup: outlier)
            }
        }
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 2a")
        // append trash values too
        if let trash = await frame.outlierGroups?.getTrash().values {
            Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV appending trash")
            for outlier in trash {
                await valueMatrix.append(outlierGroup: outlier)
            }
        }
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 2")

        try await valueMatrix.writeCSV(to: frameOutlierDir)
        Log.d("frame \(frame.frameIndex) writeOutlierValuesCSV 3")
    }
}


fileprivate let outliersFileSystemMonitor = FileSystemMonitor(max: 50)

fileprivate struct OutlierSorter: Sendable {
    public let classification: Double
    public let outlier: OutlierGroup
}

// executes the classification of .isolated blobs in parallel
fileprivate class OutlierClassifier {

    let frameIndex: Int
    let frame: FrameAirplaneRemover
    
    public init(frame: FrameAirplaneRemover)
    {
        self.frameIndex = frame.frameIndex
        self.frame = frame
    }

    // classifies OutlierGroup actors in OutlierGroups, marking them as removable or not
    // uses the .all classifier, which digs into neighboring frames for more data
    func classifyAll(_ outlierGroups: OutlierGroups,
                     overwrite: Bool = false,
                     includingTrash: Bool) async
    {
 //       await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { taskGroup in
                guard let classifier = await currentClassifier.get(for: .all) else { return }

                //let dataHarvester = await FrameDataHarvester(for: self.frame)

                let outliers = Array(await outlierGroups.getMembers().values)
                
                let max = 10            // XXX hardcoded constant

                if outliers.count > 0 {
                    for chunk in outliers.split(into: max) {
                        taskGroup.addTask {
                            for group in chunk {
                                if await group.shouldRemove() == nil || overwrite {
                                    // only apply classifier when no other classification is otherwise present
                                    // XXX we need to grab the feature data from the FrameDataHarvester
                                    //let featureData = await group.featureData(dataHarvester: dataHarvester)
                                    let classification = await classifier.classification(of: group)
                                    await group.shouldRemove(.fromClassifier(classification),
                                                            markAsChanged: false)
                                }
                            }
                        }
                    }
                }
                if includingTrash {
                    let trash = await Array(outlierGroups.getTrash().values)

                    if trash.count > 0 {
                        for chunk in trash.split(into: max) {
                            let frame = self.frame
                            taskGroup.addTask {
                                for group in chunk {
                                    if await group.shouldRemove() == nil || overwrite {
                                        // only apply classifier when no other classification is otherwise present
                                        //let featureData = await group.featureData(dataHarvester: dataHarvester)
                                        let classification = await classifier.classification(of: group)
                                        await group.shouldRemove(.fromClassifier(classification),
                                                                markAsChanged: false)
                                        await outlierGroups.promoteFromTrash(group)
                                        await frame.markAsChanged()
                                    }
                                }
                            }
                        }
                    }
                }
                await taskGroup.waitForAll()
            }
       // }.value
    }

    // classifies OutlierGroup actors in OutlierGroups, marking them as removable or not
    // uses the .all classifier, which digs into neighboring frames for more data
    func classifyAll(_ outliers: [OutlierGroup], overwrite: Bool = false) async {
//        await Task.detached(priority: .userInitiated) {
        //let dataHarvester = await FrameDataHarvester(for: self.frame)
            await withTaskGroup(of: Void.self) { taskGroup in
                guard let classifier = await currentClassifier.get(for: .all) else { return }

                let max = 10            // XXX hardcoded constant

                if outliers.count > 0 {
                    for chunk in outliers.split(into: max) {
                        taskGroup.addTask {
                            for group in chunk {
                                if await group.shouldRemove() == nil || overwrite {
                                    // only apply classifier when no other classification is otherwise present
                                    //let featureData = await group.featureData(dataHarvester: dataHarvester)
                                    let classification = await classifier.classification(of: group)
                                    await group.shouldRemove(.fromClassifier(classification),
                                                            markAsChanged: false)
                                }
                            }
                        }
                    }
                }
                await taskGroup.waitForAll()
            }
//        }.value
    }

    // classifies blobs with the .isolated classifier, and promotes them to separate groups
    func promoteAndClassify(_ blobs: [Blob],
                            trashLevel: Double = 0.0,
                            smallTrashMax: Int = 20) async
      -> ([OutlierGroup], [OutlierGroup], TimeInterval, TimeInterval, Int)
    {
        let frame = self.frame
        let frameIndex = self.frameIndex
        
        return await Task.detached(priority: .userInitiated) {
            return await withTaskGroup(of: ([OutlierSorter], TimeInterval, TimeInterval, Int).self) { taskGroup in

                // promote found blobs to outlier groups for further processing
                let classifier = await currentClassifier.get(for: .isolated) 

                //let dataHarvester = await FrameDataHarvester(for: frame, treeType: .isolated)

                let max = 20            // XXX hardcoded constant

                if blobs.count > 0 {
                    
                    for chunk in blobs.split(into: max) {
                        taskGroup.addTask {
                            var featureDataTime: TimeInterval = 0
                            var classificationTime: TimeInterval = 0
                    
                            var ret: [OutlierSorter] = []
                            for blob in chunk {

                                // make outlier group from this blob
                                let outlierGroup = await blob.outlierGroup(at: frameIndex)

                                // vertical position on screen of the center of this outlier group
                                // 0 is top
                                // 1 is bottom
                                let centerY = Double(outlierGroup.bounds.center.y)/Double(IMAGE_HEIGHT!)

                                /*
                                 to speed things up, smaller blobs are discarded.
                                 minimum blob size is relative to the y position on screen of the outlier

                                 min at the top of the screen - 20
                                 min at the middle of the screen - 10
                                 min at the bottom of the screen - 0
                                 
                                 */
                                let minSize = Int(Double(smallTrashMax)*(1.0 - centerY))

                                // don't process smaller blobs any further
                                if outlierGroup.size <= minSize {
                                    ret.append(.init(classification: -1, // classified based on size only
                                                     outlier: outlierGroup))
                                    continue
                                }
                           
                                //Log.i("frame \(frameIndex) promoting \(blob) to outlier group \(outlierGroup.id) line \(String(describing: blob.line))")
                                await outlierGroup.set(frame: frame)

                                // when promoting blobs to outlier groups, we first use the .isolated classifier
                                // and separate blobs into two groups based upon a threshold in this classification.
                                // one group is the trash, which has a very high likelyhood of not being useful
                                // the other group are the outlier groups that will get processed further

                                if let classifier {
                                    let startTime = Date().timeIntervalSince1970

                                    let featureTime = Date().timeIntervalSince1970
                                    let classification = await classifier.classification(of: outlierGroup)
                                    let classTime = Date().timeIntervalSince1970

                                    // -1 classification means bad
                                    //  1 classification means good
                                    //  0 is undecided
                                    ret.append(OutlierSorter(classification: classification,
                                                             outlier: outlierGroup))
                                    featureDataTime += featureTime - startTime
                                    classificationTime += classTime - featureTime
                                } else {
                                    Log.w("No .isolated classifier!!") // assume it's good
                                  ret.append(.init(classification: 1,
                                                   outlier: outlierGroup))
                                }
                            }
                            return (ret,
                                    featureDataTime,
                                    classificationTime,
                                    chunk.count)
                        }
                    }
                }

                var good: [OutlierGroup] = []
                var bad: [OutlierGroup] = []

                var totalFeatureTime: TimeInterval = 0
                var totalClassificationTime: TimeInterval = 0
                var totalOutliers: Int = 0
                
                for await (values, featureTime, classTime, chunkCount) in taskGroup {
                    totalFeatureTime += featureTime
                    totalClassificationTime += classTime
                    totalOutliers += chunkCount
                    for value in values {
                        if value.classification > trashLevel {
                            // it's good
                            good.append(value.outlier)
                        } else {
                            // it's bad
                            bad.append(value.outlier)
                        }
                    }
                }

                return (good, bad, totalFeatureTime, totalClassificationTime, totalOutliers)
            }
        }.value
    }
}

fileprivate func foreachOutlier(in outliers: [OutlierGroup],
                                with trash: [OutlierGroup],
                                _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Void) async {
    await withTaskGroup(of: Void.self) { taskGroup in

        // max number of concurrent tasks (for each outliers and trash)
        let max = 10            // XXX hardcoded constant

        let outlierChunkSize = outliers.count/max
        let trashChunkSize = trash.count/max

        if outliers.count > 0 {
            for chunk in outliers.chunks(of: outlierChunkSize) {
                taskGroup.addTask() {
                    for group in chunk {
                        await closure(group, false)
                    }
                }
            }
        }
        if trash.count > 0 {
            for chunk in trash.chunks(of: trashChunkSize) {
                taskGroup.addTask() {
                    for group in chunk {
                        await closure(group, true)
                    }
                }
            }
        }
        await taskGroup.waitForAll()
    }
}

extension String {
    /// Returns the substring after the last "/" in this string,
    /// or `nil` if "/" is not found.
    func substringAfterLastSlash() -> String? {
        guard let idx = self.lastIndex(of: "/") else { return nil }
        let next = self.index(after: idx)
        return String(self[next...])
    }
}

import Foundation

/// Removes *only* the files in the specified directory path (non‐recursive).
/// Subdirectories (and their contents) are left untouched.
/// - Parameter directoryPath: the file‐system path of an existing directory.
/// - Throws: any FileManager errors encountered during listing or removal.
func removeAllFiles(in directoryPath: String) throws {
    // Convert String path → URL
    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
    try removeAllFiles(in: directoryURL)
}

/// Removes *only* the files in the specified directory URL (non‐recursive).
/// Subdirectories (and their contents) are left untouched.
/// - Parameter directoryURL: the URL of an existing directory
/// - Throws: any FileManager errors encountered during listing or removal
func removeAllFiles(in directoryURL: URL) throws {
    let fm = FileManager.default

    // Ensure the URL actually points to a directory
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: directoryURL.path, isDirectory: &isDir),
          isDir.boolValue
    else {
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "Directory not found at \(directoryURL.path)"]
        )
    }

    // List only the top‐level contents of the directory
    let contents = try fm.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )

    for fileURL in contents {
        // Skip subdirectories
        let resourceVals = try fileURL.resourceValues(forKeys: [.isDirectoryKey])
        if resourceVals.isDirectory == true { continue }

        // Remove the file
        try fm.removeItem(at: fileURL)
    }
}
