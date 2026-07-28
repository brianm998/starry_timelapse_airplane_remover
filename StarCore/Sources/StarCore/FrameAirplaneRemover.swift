import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, URLRequest live here on Linux
#endif
import StarCppBridge
import Semaphore
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

// used for finding outliers in frames when processing
public let maxFramesProcessing = IntegralActor(value: 20) // XXX read this initial value from #-CPU's

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

    public func getObserver() -> FrameObserver? { observer }
    
    public weak var observer: FrameObserver?

    public func set(observer: FrameObserver) {
        self.observer = observer

        Task {
            await observer.set(cleanMethod: cleanMethod)
            if let results = await alignmentProcessor.readEarthNeighborHomographyForThisFrame() {
                //Log.d("frame \(frameIndex) setting number of earth alignments \(results)")
                await observer.set(earthAlignmentResults: results)
            } else {
                //Log.d("frame \(frameIndex) NO number of earth alignments")
            }

            if let results = await alignmentProcessor.readStarNeighborHomographyForThisFrame() {
                //Log.d("frame \(frameIndex) setting number of star alignments \(results)")
                await observer.set(starAlignmentResults: results)
            } else {
                //Log.d("frame \(frameIndex) NO number of star alignments")
            }
        }
    }
    
    public func set(state: FrameProcessingState) {
        Log.i("frame \(frameIndex) transitioning to state \(state)")
        self.state = state
        if state == .complete {
            Task { await self.releaseRecomputableState(alsoNudgingNeighbours: true) }
        }
    }

    /// Release the per-frame buffers that can be rebuilt on demand.
    ///
    /// These are caches, not state. `outlierImageData` is rebuilt by
    /// `OutlierGroups.outlierImageDataFunc()` from the groups the frame still holds, and
    /// `cachedFinalHorizonMask` by `loadOrCreateFinalHorizonMask()` from the mask on
    /// disk. Nothing is lost by dropping them — but at 42MP they are ~80MB and ~40MB
    /// per frame, they live as long as the frame does, and no reservation covers them:
    /// the MemoryMonitor never hears about them at all. Across a long sequence that
    /// accumulation is larger than anything the gate does account for.
    ///
    /// Neighbours read this frame's `outlierImageData` while classifying — see
    /// OutlierGroupFeature's nearbyDirectOverlapScore / boundingBoxOverlapScore /
    /// neighborLineThetaScore, which reach into the previous and next frames — so it can
    /// be re-materialised after we drop it. That is why a completing frame also nudges
    /// any already-complete neighbour: frame N+1 completing collects the buffer that
    /// N+1's own classification rebuilt on frame N. Without that, the steady state is
    /// one live buffer per frame again, which is what we are trying to avoid.
    ///
    /// Deliberately does NOT drop `skyKeyPoints` / `earthKeyPoints`: they are ~1MB
    /// against the ~120MB above, and their `didSet` reports keypoint counts to the
    /// frame observer, so clearing them would make completed frames read as having zero
    /// keypoints in the UI.
    public func releaseRecomputableState(alsoNudgingNeighbours: Bool = false) async {
        Log.d("frame \(frameIndex) releasing recomputable per-frame buffers" +
              (alsoNudgingNeighbours ? " (and nudging neighbours)" : " (nudged)"))
        await outlierProcessor.releaseOutlierImageData()
        await horizonProcessor.releaseCachedFinalHorizonMask()

        // One level only — a nudged neighbour must not nudge back.
        guard alsoNudgingNeighbours else { return }
        for neighbour in [previousFrame, nextFrame] {
            guard let neighbour else { continue }
            if await neighbour.processingState() == .complete {
                await neighbour.releaseRecomputableState()
            }
        }
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
        
        if let outlierGroups = await outlierProcessor.getOutlierGroups() {
            await outlierGroups.asyncHash(into: &hasher)
        }
    }
    
    nonisolated public let width: Int
    nonisolated public let height: Int
    nonisolated public let componentsPerPixel: Int
    nonisolated public let frameIndex: Int

    // populated by pruning

    public func getOutlierGroups() async -> OutlierGroups? { await outlierProcessor.getOutlierGroups() }
    
    // Goes through set(state:) rather than assigning directly so the completion hook
    // that releases this frame's recomputable buffers actually fires.
    public func changesHandled() { self.set(state: .complete) }

    public func updateCombineSubjects() async {
        if let outlierGroups = await outlierProcessor.getOutlierGroups() {
            let outliers = await outlierGroups.getMembers()
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

            let trashCount = await outlierGroups.getTrash().count
            
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

    // doubly linked list
    public weak var previousFrame: FrameAirplaneRemover?
    public weak var nextFrame: FrameAirplaneRemover?

    public func getPreviousFrame() -> FrameAirplaneRemover? { previousFrame }
    
    public func setPreviousFrame(_ frame: FrameAirplaneRemover) {
        previousFrame = frame
    }

    public func getNextFrame() -> FrameAirplaneRemover? { nextFrame }
    
    public func setNextFrame(_ frame: FrameAirplaneRemover) {
        nextFrame = frame
    }

    // if this is false, just write out outlier data
    let writeOutputFiles: Bool

    nonisolated public let imageAccessor: ImageAccessor

    private let completion: (() async -> Void)?
    

    private weak var imageSequence: ImageSequence?

    internal let alignmentProcessor: FrameAlignmentProcessor
    internal let horizonProcessor: FrameHorizonProcessor
    internal let outlierProcessor: FrameOutlierProcessor

    // Set by FrameGraphBuilder for static sequences; nil for moving sequences.

    public init(with configManager: ConfigManager,
                initialConfig: Config,
                width: Int,
                height: Int,
                componentsPerPixel: Int,
                callbacks: Callbacks,
                imageSequence: ImageSequence,
                atIndex frameIndex: Int,
                outputFilename: String,
                baseName: String,       // source filename without path
                writeOutputFiles: Bool = true,
                imageAccessor: ImageAccessor,
                completion: (@Sendable () async -> Void)? = nil) async throws
    {
        //Log.d("frame \(frameIndex) init begin")
        self.imageSequence = imageSequence
        self.imageAccessor = imageAccessor
        self.writeOutputFiles = writeOutputFiles
        self.configManager = configManager
        self.baseName = baseName
        self.callbacks = callbacks
        self.frameIndex = frameIndex // frame index in the image sequence
        self.outputFilename = outputFilename
        self.completion = completion
        self.width = width
        self.height = height

        self.componentsPerPixel = componentsPerPixel

        self.alignmentProcessor = FrameAlignmentProcessor(
            frameIndex: frameIndex,
            width: width,
            height: height,
            componentsPerPixel: componentsPerPixel,
            imageAccessor: imageAccessor,
            configManager: configManager,
            imageSequence: imageSequence
        )
        self.horizonProcessor = FrameHorizonProcessor(
            frameIndex: frameIndex,
            imageAccessor: imageAccessor,
            configManager: configManager,
            imageSequence: imageSequence
        )
        self.outlierProcessor = FrameOutlierProcessor(
            frameIndex: frameIndex,
            imageAccessor: imageAccessor,
            configManager: configManager,
            callbacks: callbacks,
            imageSequence: imageSequence,
            width: width,
            height: height,
            componentsPerPixel: componentsPerPixel
        )

        // call directly in init becuase didSet() isn't called from here :P
        await alignmentProcessor.setFrame(self)
        await horizonProcessor.setFrame(self)
        await outlierProcessor.setFrame(self)
        //Log.d("config.numberAlignedNeighborFrames \(config.numberAlignedNeighborFrames)")
        await alignmentProcessor.setNumberOfAlignedFrames(with: initialConfig)
        await alignmentProcessor.setNumberOfStaticNeighborFrames(with: initialConfig)
        await self.set(
          cleanMethod: initialConfig.cleanMethod(for: frameIndex),
          process: false,
          update: false
        )
        //Log.d("frame \(frameIndex) init mid")
        
        if imageAccessor.imageExists(frameIndex: frameIndex,
                                     ofType: .final,
                                     atSize: .original)
        {
            self.state = .complete
        } else if FileManager.default.fileExists(atPath: "\(await outlierProcessor.outliersDirname)/\(BlobBinarySaver.outlierBinaryFilename)") {
            // if we have outliers, mark it as userModified (classified),
            // even if some are not classified
            self.state = .userModified
        }
        //Log.d("frame \(frameIndex) init mid 2")
        
        if let frameStateChangeCallback = callbacks.frameStateChangeCallback {
            frameStateChangeCallback(self, self.state)
        }

        await self.updateCombineSubjects()
        //Log.d("frame \(frameIndex) init end")

    }

    // threshold used for throwing out bad pixels before replacing with them
    public var pixelThreshold: Double {
        get async {
            let config = await configManager.config()
            return config.pixelThreshold
        }
    }

          
    /// Deletes star-alignment-related cached images and keypoint files for this
    /// frame if they have already been computed.  Returns `true` when something
    /// was invalidated so the caller knows whether to trigger reprocessing.
    /// Only alignment files are removed; horizon masks are left intact.
    public func invalidateStarAlignmentIfExists() async throws -> Bool {
        /*
        guard imageAccessor.imageExists(
          frameIndex: frameIndex,
          ofType: .starAligned,
          atSize: .original
          ) else { return false }
         */
        imageAccessor.deleteImages(
          frameIndex: frameIndex,
          ofTypes: [.starAligned, .earthAligned, .subtraction,
                    .autoProcessed, .autoSelectiveProcessed, .selectiveProcessed, .final],
          atSizes: [.original, .preview]
        )
        try await alignmentProcessor.removeNumberOfAlignedImagesForThisFrameFile()
        try await alignmentProcessor.removeNeighborStarHomography()
        // Clear in-memory homography caches so reprocessing recomputes them
        // rather than reusing the stale cached values.
        await alignmentProcessor.clearHomographyCache()
        self.state = .unprocessed
        return true
    }
    

    public nonisolated func process(
      startIndex: Int = 0,
      endIndex: Int? = nil,      // will be last index of frames
      progressClosure: @Sendable @escaping (SequenceProcessingState) -> Void
    ) async {
        Log.d("processAll")

        Task.detached(priority: .userInitiated) {
            // build with a graph of dependencies between different frames at
            // different steps of the process
            await frameGraphBuilder.build(
              frames: await self.allFrames,
              startIndex: startIndex,
              endIndex: endIndex
            ) { errorArray in
                if errorArray.count == 0 {
                    // success
                    progressClosure(.done) // XXX make more of these
                } else {
                    // some failures, also reported in errorClosure first
                    progressClosure(.error(String(errorArray.joined(separator: "\n"))))
                }
            } errorClosure: { errorString in
                Log.e("handle this error: \(errorString)")
            }
        }
    }

    
    public var allFrames: [FrameAirplaneRemover] {
        get async {
            var nextFrame: FrameAirplaneRemover? = await self.firstFrameInSequence
            var ret: [FrameAirplaneRemover] = []
            while nextFrame != nil {
                if let frame = nextFrame {
                    ret.append(frame)
                    nextFrame = await frame.getNextFrame()
                }
            }
            return ret
        }
    }

    var firstFrameInSequence: FrameAirplaneRemover {
        get async {
            var firstFrame = self
            while await firstFrame.getPreviousFrame() != nil {
                if let prev = await firstFrame.getPreviousFrame() {
                    firstFrame = prev
                }
            }
            return firstFrame
        }
    }
    

    public func deleteAllProcessedImages() {
        for viewMode in FrameViewMode.allCases {
            if viewMode == .original { continue }

            try? imageAccessor.deleteImage(frameIndex: frameIndex,
                                           ofType: viewMode,
                                           atSize: .original)

            try? imageAccessor.deleteImage(frameIndex: frameIndex,
                                           ofType: viewMode,
                                           atSize: .preview)
            
        }
    }
    public func deleteMergeOutput() {
        imageAccessor.deleteImages(
            frameIndex: frameIndex,
            ofTypes: [.autoProcessed, .autoSelectiveProcessed, .selectiveProcessed, .final],
            atSizes: [.original, .preview]
        )
        if state == .complete {
            state = .outlierProcessingComplete
        }
    }

    public func removeSubtractionImages() {
        // get rid of the subtraction here image too,
        // as it is a product of the star aligned images
        try? imageAccessor.deleteImage(frameIndex: frameIndex,
                                       ofType: .subtraction,
                                       atSize: .original)

        try? imageAccessor.deleteImage(frameIndex: frameIndex,
                                       ofType: .subtraction,
                                       atSize: .preview)
    }


    public func finish() async throws {
        switch await self.cleanMethod {
        case .automatic(let useOutliers):
            try await self.finishAuto(useOutliers: useOutliers)
        case .selective:
            try await self.finishSelective()
        }
    }
    
    // run after shouldRemove has been set for each group,
    // does the final removing and then writes out the output files
    public func finishSelective() async throws {
        Log.d("frame \(self.frameIndex) starting to finish")

        // Gate on memory before loading the original image for final output
        let estimatedBytes = MemoryMonitor.estimatedImageBytes(
            width: width,
            height: height,
            componentsPerPixel: componentsPerPixel
        )
        await MemoryMonitor.shared.waitForMemory(needed: estimatedBytes)

        mkdir(await outlierProcessor.outliersDirname)
        
        await outlierProcessor.writeOutliersRemoveReasons()

        self.set(state: .finishing)

        let config = await configManager.config()
        
        if config.writeOutlierClassificationValues {
            // THIS MOFO IS SLOW
            self.set(state: .writingOutlierValues)

            Log.d("frame \(self.frameIndex) finish 1")
            // write out the classifier feature data for this data point
            try await outlierProcessor.writeOutlierValuesCSV()
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

        guard var image = image
        else { throw "couldn't load original file for finishing" }
        
        image = image.ensure16Bits
        
        /*
        if self.writeOutputFiles {
            self.set(state: .loadingImages1)
            try await imageAccessor.save(
              image, 
              frameIndex: frameIndex,
              as: .original,
              atSize: .preview,
              overwrite: false
            )
            try await imageAccessor.save(
              image,
              frameIndex: frameIndex,
              as: .original,
              atSize: .thumbnail,
              overwrite: false
            )
        }*/

        var horizonMask: HorizonMask? = nil
        var earthAlignedImage: PixelatedImage? = nil
        
        if config.horizonDetectionEnabled {
            // only load these if we really need them
            var horizonMaskImage: PixelatedImage? = nil
            let result = try await alignmentProcessor.loadOrCreateEarthAlignedImage()
            if let mat = result.warpedFrame {
                earthAlignedImage = PixelatedImage(mat: mat.ensure16Bits())
            }
            if let mat = result.warpedHorizon {
                horizonMaskImage = PixelatedImage(mat: mat)
            }
              
            if let horizonMaskImage {
                horizonMask = HorizonMask(horizonMaskImage)
            } else {
                Log.w("frame \(frameIndex) falling back to non-merged horizon mask")
                horizonMask = try await horizonProcessor.loadOrCreateFinalHorizonMask()
            }
        }

        let alignmentResult = try await alignmentProcessor.loadOrCreateStarAlignedImage()
        
        let starAlignedImage = alignmentResult.warpedFrame

        var skyAlignedImage: PixelatedImage? = nil
        if let starAlignedImage {
            skyAlignedImage = PixelatedImage(mat: starAlignedImage.ensure16Bits())
        }

        guard let skyAlignedImage else {
            Log.e("frame \(frameIndex) Cannot selective finish without a successful or failed star alignment image")
            throw "frame \(frameIndex) Cannot selective finish without a successful or failed star alignment image"
        }
        let format = image.imageData

        switch format {
        case .thirtyTwoBit(_):
            fatalError("frame \(self.frameIndex) cannot load 32 bit image here now")
                
        case .eightBit(_):
            Log.e("8 bit not supported here now")
            
        case .sixteenBit(let outputData):
            Log.d("frame \(self.frameIndex) removing airplanes")

            // copy the outputData to a new Buffer
            var newImageBuffer = ImageBuffer<UInt16>(
              pointer: outputData,
              width: image.width,
              height: image.height,
              components: image.componentsPerPixel
            )
            
            try await self.removeAirplanes(
              image: image,
              toData: &newImageBuffer,
              starAlignedImage: skyAlignedImage,
              earthAlignedImage: earthAlignedImage,
              horizonMask: horizonMask
            )

            Log.d("frame \(self.frameIndex) writing output files")
            self.set(state: .writingOutputFile)

            Log.d("frame \(self.frameIndex) updating image")
            
            if var processedImage = newImageBuffer.image {
                // write frame out as processed versions

                if config.imageBitsPerComponent == 8 {
                    Log.d("making output image 8 bits per component")
                    // make sure we save the image as 8 bits per component
                    processedImage = processedImage.ensure8Bits   
                }
                let outputSizes = await self.outputSizes
                do {
                    Log.d("frame \(self.frameIndex) processed file")
                    try await imageAccessor.save(
                      processedImage,
                      frameIndex: frameIndex,
                      as: .selectiveProcessed,
                      atSizes: outputSizes,
                      overwrite: true
                    )

                    // link to final here
                    try await imageAccessor.linkFinals(
                      frameIndex: frameIndex,
                      as: .selectiveProcessed,
                      atSizes: outputSizes
                    )
                    
                } catch {
                    // XXX for some reason this error gets missed if we don't catch it here :(
                    Log.d("frame \(self.frameIndex) ERROR \(error)")

                }
                if let outlierGroups = await outlierProcessor.getOutlierGroups() {
                    Log.d("frame \(self.frameIndex) getting validating image")
                    if let validationImage = await outlierGroups.validationImage() {
                        Log.d("frame \(self.frameIndex) writing validated image")
                        try await imageAccessor.save(
                          validationImage,
                          frameIndex: frameIndex,
                          as: .validation,
                          atSizes: outputSizes,
                          overwrite: false
                        )
                    } else {
                        Log.w("frame \(self.frameIndex) cannot create validation image")
                    }
                }
                Log.d("frame \(self.frameIndex) done writing output files")
            } else {
                Log.w("frame \(self.frameIndex) unable to make new processed image buffer")
            }
        }
        self.set(state: .complete)
        await MemoryMonitor.shared.memoryFreed()
        if let completion { await completion() }

        Log.i("frame \(self.frameIndex) complete")
    }

    public var outputSizes: [ImageDisplaySize] {
        get async {
            var sizes: [ImageDisplaySize] = [.original]
            let config = await configManager.config()
            if config.writeFramePreviewFiles {
                sizes.append(.preview)
            }
            return sizes
        }
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frameIndex == rhs.frameIndex
    }

    // MARK: - Horizon forwarding

    func setHorizonAccumulator(_ acc: HorizonAccumulator) async {
        await horizonProcessor.setHorizonAccumulator(acc)
    }
    public func accumulateDetectedHorizon(_ mask: HorizonMask) async {
        await horizonProcessor.accumulateDetectedHorizon(mask)
    }
    public func recomputeMergedHorizonIfExists() async throws {
        try await horizonProcessor.recomputeMergedHorizonIfExists()
    }
    public func recomputeMergedHorizon() async throws {
        try await horizonProcessor.recomputeMergedHorizon()
    }
    internal func loadOrCreateHorizonMask() async throws -> HorizonMask {
        try await horizonProcessor.loadOrCreateHorizonMask()
    }
    internal func loadOrCreateFinalHorizonMask() async throws -> HorizonMask? {
        try await horizonProcessor.loadOrCreateFinalHorizonMask()
    }
    public func loadOrCreateMergedHorizonMask() async throws -> HorizonMask? {
        try await horizonProcessor.loadOrCreateMergedHorizonMask()
    }
    public func createMergedHorizonMask() async throws -> HorizonMask? {
        try await horizonProcessor.createMergedHorizonMask()
    }
    public func loadTunedHorizonParameters() async -> HorizonTunedParameters {
        await horizonProcessor.loadTunedHorizonParameters()
    }
    public func saveTunedHorizonParameters(_ params: HorizonTunedParameters) async throws {
        try await horizonProcessor.saveTunedHorizonParameters(params)
    }
    public func computeLiveObjectSelection(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        bandMode: Bool = false,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        try await horizonProcessor.computeLiveObjectSelection(
            topBoundaryY: topBoundaryY,
            bottomBoundaryY: bottomBoundaryY,
            viewWidth: viewWidth, viewHeight: viewHeight,
            bandMode: bandMode,
            knownSkyFloorY: knownSkyFloorY,
            knownGroundCeilingY: knownGroundCeilingY
        )
    }
    public func computeCombinedHorizonInBand(
        topBoundaryY: [Int?],
        bottomBoundaryY: [Int?],
        viewWidth: Int,
        viewHeight: Int,
        knownSkyFloorY: [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        try await horizonProcessor.computeCombinedHorizonInBand(
            topBoundaryY: topBoundaryY,
            bottomBoundaryY: bottomBoundaryY,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            knownSkyFloorY: knownSkyFloorY,
            knownGroundCeilingY: knownGroundCeilingY
        )
    }
    public func computeRandomWalkerHorizon(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil,
        beta: Double = 90.0
    ) async throws -> [Int?] {
        try await horizonProcessor.computeRandomWalkerHorizon(
            topBoundaryY: topBoundaryY,
            bottomBoundaryY: bottomBoundaryY,
            viewWidth: viewWidth,
            viewHeight: viewHeight,
            knownSkyFloorY: knownSkyFloorY,
            knownGroundCeilingY: knownGroundCeilingY,
            beta: beta
        )
    }
    public func loadExistingHorizonReferenceAsViewY(viewWidth: Int, viewHeight: Int) async throws -> [Int?]? {
        try await horizonProcessor.loadExistingHorizonReferenceAsViewY(viewWidth: viewWidth, viewHeight: viewHeight)
    }
    public func loadBestExistingHorizonAsViewY(viewWidth: Int, viewHeight: Int) async throws -> [Int?]? {
        try await horizonProcessor.loadBestExistingHorizonAsViewY(viewWidth: viewWidth, viewHeight: viewHeight)
    }
    public var hasHorizonReference: Bool {
        get async { await horizonProcessor.hasHorizonReference }
    }
    public func loadHorizonThumbnailOverlay(thumbnailWidth: Int, thumbnailHeight: Int) async throws -> HorizonThumbnailOverlay? {
        try await horizonProcessor.loadHorizonThumbnailOverlay(thumbnailWidth: thumbnailWidth, thumbnailHeight: thumbnailHeight)
    }
    public func saveHorizonReferenceMask(
        paintedYPerColumn: [Int?],
        viewWidth: Int,
        viewHeight: Int
    ) async throws {
        try await horizonProcessor.saveHorizonReferenceMask(
            paintedYPerColumn: paintedYPerColumn,
            viewWidth: viewWidth,
            viewHeight: viewHeight
        )
    }
    public func deleteHorizonImages() async {
        await horizonProcessor.deleteHorizonImages()
    }

    // MARK: - Outlier forwarding

    // Computed-property forwarders
    public var userSliceDirname: String { get async { await outlierProcessor.userSliceDirname } }
    public var userSliceFilename: String { get async { await outlierProcessor.userSliceFilename } }
    public var blobBinaryFilename: String { get async { await outlierProcessor.blobBinaryFilename } }
    public var trashBinaryFilename: String { get async { await outlierProcessor.trashBinaryFilename } }
    public var outliersDirname: String { get async { await outlierProcessor.outliersDirname } }

    // Outlier setup / loading / detection
    public func setupOutliers() async throws { try await outlierProcessor.setupOutliers() }
    public func getUserSlices() async -> [BoundingBox] { await outlierProcessor.getUserSlices() }
    public func loadOutliersFromFile() async -> OutlierGroups? { await outlierProcessor.loadOutliersFromFile() }
    public func loadOutliersFromBinaryFile() async throws -> OutlierGroups? { try await outlierProcessor.loadOutliersFromBinaryFile() }
    public func loadOutliers(loadOnly: Bool = false) async throws { try await outlierProcessor.loadOutliers(loadOnly: loadOnly) }
    public func initializeEmptyOutlierGroups() async { await outlierProcessor.initializeEmptyOutlierGroups() }
    public func findOutliers() async throws { try await outlierProcessor.findOutliers() }
    public func findOutliers(within bounds: BoundingBox) async throws { try await outlierProcessor.findOutliers(within: bounds) }
    public func maybeApplyOutlierGroupClassifier() async throws { try await outlierProcessor.maybeApplyOutlierGroupClassifier() }
    public func applyDecisionTreeToAllOutliers(overwrite: Bool = true, minimumSize: Int? = nil) async {
        await outlierProcessor.applyDecisionTreeToAllOutliers(overwrite: overwrite, minimumSize: minimumSize)
    }
    public func applyDecisionTreeToAutoSelectedOutliers(includingTrash: Bool, overwrite: Bool = false, minimumSize: Int? = nil) async {
        await outlierProcessor.applyDecisionTreeToAutoSelectedOutliers(includingTrash: includingTrash, overwrite: overwrite, minimumSize: minimumSize)
    }
    public func clearOutlierGroupValueCaches(includingTrash: Bool) async {
        await outlierProcessor.clearOutlierGroupValueCaches(includingTrash: includingTrash)
    }

    // Outlier-group queries (getOutlierGroups already declared above)
    public func outlierGroupList() async -> [OutlierGroup]? { await outlierProcessor.outlierGroupList() }
    public func outlierGroupTrashList() async -> [OutlierGroup]? { await outlierProcessor.outlierGroupTrashList() }
    public func outlierGroup(named outlierName: UInt16) async -> OutlierGroup? { await outlierProcessor.outlierGroup(named: outlierName) }
    public func foreachOutlierGroup(includingTrash: Bool, _ closure: @Sendable (OutlierGroup, Bool) async -> Bool) async -> Bool {
        await outlierProcessor.foreachOutlierGroup(includingTrash: includingTrash, closure)
    }
    public func foreachOutlierGroupMulti(includingTrash: Bool, _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool) async -> Bool {
        await outlierProcessor.foreachOutlierGroupMulti(includingTrash: includingTrash, closure)
    }
    public func foreachOutlierGroupMulti(between startLocation: CGPoint, and endLocation: CGPoint, includingTrash: Bool, _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool) async -> Bool {
        await outlierProcessor.foreachOutlierGroupMulti(between: startLocation, and: endLocation, includingTrash: includingTrash, closure)
    }

    // User-selection methods
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool, includingTrash: Bool) async -> Bool {
        await outlierProcessor.userSelectAllOutliers(toShouldRemove: shouldRemove, includingTrash: includingTrash)
    }
    public func userSelectUndecidedOutliers(toShouldRemove shouldRemove: Bool, includingTrash: Bool) async -> Bool {
        await outlierProcessor.userSelectUndecidedOutliers(toShouldRemove: shouldRemove, includingTrash: includingTrash)
    }
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool, overlapping group: OutlierGroup) async -> Bool {
        await outlierProcessor.userSelectAllOutliers(toShouldRemove: shouldRemove, overlapping: group)
    }
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool, between startLocation: CGPoint, and endLocation: CGPoint, includingTrash: Bool) async {
        await outlierProcessor.userSelectAllOutliers(toShouldRemove: shouldRemove, between: startLocation, and: endLocation, includingTrash: includingTrash)
    }

    // Manipulation
    public func applyRazor(in boundingBox: BoundingBox, includingTrash: Bool) async throws {
        try await outlierProcessor.applyRazor(in: boundingBox, includingTrash: includingTrash)
    }
    public func promoteDust(in boundingBox: BoundingBox) async throws -> [OutlierGroup] {
        try await outlierProcessor.promoteDust(in: boundingBox)
    }
    public func deleteOutliers() async throws { try await outlierProcessor.deleteOutliers() }
    public func deleteOutliers(in boundingBox: BoundingBox) async throws {
        try await outlierProcessor.deleteOutliers(in: boundingBox)
    }
    public func saveImages(for blobs: [Blob], as frameImageType: FrameViewMode) async throws {
        try await outlierProcessor.saveImages(for: blobs, as: frameImageType)
    }

    // File output
    public func writeOutlierValuesCSV() async throws { try await outlierProcessor.writeOutlierValuesCSV() }
    public func writeOutliersRemoveReasons() async { await outlierProcessor.writeOutliersRemoveReasons() }

    // MARK: - Alignment forwarding
    // All callers use `await` (actor isolation), so adding async here is a no-op for them.

    public func skyKeyPointCount() async -> Int { await alignmentProcessor.skyKeyPointCount() }
    public func earthKeyPointCount() async -> Int { await alignmentProcessor.earthKeyPointCount() }
    public var numberOfAlignedFrames: Int {
        get async { await alignmentProcessor.numberOfAlignedFrames }
    }

    public func setNumberOfStaticNeighborFrames(with config: Config? = nil) async {
        await alignmentProcessor.setNumberOfStaticNeighborFrames(with: config)
    }
    public func setNumberOfAlignedFrames(with config: Config? = nil) async {
        await alignmentProcessor.setNumberOfAlignedFrames(with: config)
    }
    public func getHorizonMergeIndices() async -> [Int] {
        await alignmentProcessor.getHorizonMergeIndices()
    }
    public func getAlignmentFrameIndices() async -> [Int] {
        await alignmentProcessor.getAlignmentFrameIndices()
    }
    public func getStaticNeighborFrames() async -> [Int] {
        await alignmentProcessor.getStaticNeighborFrames()
    }
    public func getStaticNeighborFilenames() async -> [String] {
        await alignmentProcessor.getStaticNeighborFilenames()
    }
    public func set(neighborStarHomography: HomographyResultsCodable) async {
        await alignmentProcessor.set(neighborStarHomography: neighborStarHomography)
    }
    public func set(neighborEarthHomography: HomographyResultsCodable) async {
        await alignmentProcessor.set(neighborEarthHomography: neighborEarthHomography)
    }
    public func getNeighborStarHomography() async -> HomographyResultsCodable? {
        await alignmentProcessor.getNeighborStarHomography()
    }
    public func getNeighborEarthHomography() async -> HomographyResultsCodable? {
        await alignmentProcessor.getNeighborEarthHomography()
    }
    internal func loadOrCreateHomography(of type: FrameViewMode) async throws -> HomographyResultsCodable? {
        try await alignmentProcessor.loadOrCreateHomography(of: type)
    }
    public func loadOrCreateEarthFeatures() async throws -> OCVFeatureSet? {
        try await alignmentProcessor.loadOrCreateEarthFeatures()
    }
    public func loadOrCreateStarFeatures() async throws -> OCVFeatureSet? {
        try await alignmentProcessor.loadOrCreateStarFeatures()
    }
    func loadOrCreateOCVFeatures(of type: FrameViewMode) async throws -> OCVFeatureSet? {
        try await alignmentProcessor.loadOrCreateOCVFeatures(of: type)
    }
    public func removeNeighborStarHomography() async throws {
        try await alignmentProcessor.removeNeighborStarHomography()
    }
    public func readStarNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await alignmentProcessor.readStarNeighborHomographyForThisFrame()
    }
    public func readEarthNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await alignmentProcessor.readEarthNeighborHomographyForThisFrame()
    }
    public func removeNumberOfAlignedImagesForThisFrameFile() async throws {
        try await alignmentProcessor.removeNumberOfAlignedImagesForThisFrameFile()
    }

    // Mark - Removal

    // this is the inverse of removeAirplanes, it replaces them in the auto image
    internal func replaceAirplanes(
      image: PixelatedImage,
      toData data: inout ImageBuffer<UInt16>,
      originalImage: PixelatedImage
    ) async throws {

        let (shouldRemove, alphaLevels, alphaYAxis) = try await computeRemovalMask()

        if shouldRemove {
            self.set(state: .assemblingProcessedFrame)
            for y in 0 ..< height {
                if alphaYAxis[y] == 0 { continue }
                for x in 0 ..< width {
                    var alpha = alphaLevels[y*width+x]
                    if alpha > 0 {
                        if alpha > 1 { alpha = 1 }


                        self.updatePixel(
                          x: x, y: y,
                          alpha: alpha,
                          toData: &data,
                          image: image,
                          with: originalImage.readPixel(atX: x, andY: y)
                        )
                    }
                }
            }
        } else {
            Log.i("frame \(frameIndex) NOT removing bad pixels")
        }
    }
    
    /*
     Logic about removing undesired elements from the image.

     Removing is done with data from a neighboring, aligned frame.

     Pixels to be removed come from validated outlier groups,
     that logic is elsewhere.
     */

    // actually remove outlier groups that have been selected as airplane tracks
    internal func removeAirplanes(
      image: PixelatedImage,
      toData data: inout ImageBuffer<UInt16>,
      starAlignedImage: PixelatedImage,
      earthAlignedImage: PixelatedImage?,
      horizonMask: HorizonMask?
    ) async throws {
        Log.i("frame \(frameIndex) removing airplane outlier groups")

        if let earthAlignedImage,
           let horizonMask
        {
            guard(starAlignedImage.width == earthAlignedImage.width && 
                  horizonMask.image.width == earthAlignedImage.width &&
                  starAlignedImage.height == earthAlignedImage.height &&
                  horizonMask.image.height == earthAlignedImage.height)
            else {
                Log.e("cannot remove airplanes with starAlignedImage.width \(starAlignedImage.width) earthAlignedImage.width \(earthAlignedImage.width) horizonMask.image.width \(horizonMask.image.width) starAlignedImage.height \(starAlignedImage.height) earthAlignedImage.height \(earthAlignedImage.height) horizonMask.image.height \(horizonMask.image.height)")
                return
            }
        }

        var expendedHorizonMaskImage: PixelatedImage? = nil
        
        if let horizonMask {
            // raise the mask with a gradient to allow replacement pixel values to come
            // from the earth aligned image when they are this close to the horizon
            expendedHorizonMaskImage = horizonMask.image.raiseMaskBy(60) // XXX hardcoded constant
        }
        
        // remove every outlier in the list with pixels from the adjecent frames
        guard let outlierGroups = await outlierProcessor.getOutlierGroups() else {
            Log.e("cannot remove pixels without outlier groups")
            return
        }

        guard await outlierGroups.getMembers().count > 0 else {
            Log.v("no outliers, not removing")
            return
        }


        let (shouldRemove, alphaLevels, alphaYAxis) = try await computeRemovalMask()

        if shouldRemove {
            Log.i("frame \(frameIndex) removing bad pixels")
            self.set(state: .assemblingProcessedFrame)
            
            // then actually remove each non zero alpha pixel,
            // replacing it with one calculated from other frames
            for y in 0 ..< height {
                if alphaYAxis[y] == 0 { continue }
                for x in 0 ..< width {
                    var alpha = alphaLevels[y*width+x]
                    if alpha > 0 {
                        if alpha > 1 { alpha = 1 }

                        updatePixel(
                          x: x,
                          y: y,
                          alpha: alpha,
                          toData: &data,
                          image: image,
                          starAlignedImage: starAlignedImage,
                          earthAlignedImage: earthAlignedImage,
                          horizonMask: expendedHorizonMaskImage
                        )
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
        } else {
            Log.i("frame \(frameIndex) NOT removing bad pixels")
        }
    }

    internal func computeRemovalMask() async throws -> (Bool, [Double], [UInt8]) {
        self.set(state: .creatingRemovalMask)

        // remove every outlier in the list with pixels from the adjecent frames
        guard let outlierGroups = await outlierProcessor.getOutlierGroups() else {
            Log.e("cannot remove pixels without outlier groups")
            return (false, [], [])
        }
        
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
        let removeMask = RemoveMask(
          innerWallSize: config.outlierGroupPaintBorderInnerWallPixels,
          radius: config.outlierGroupPaintBorderPixels
        )
        
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
            var removeMaskImageData = ImageBuffer<UInt8>(width: width, height: height)

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

            if let removeMaskImage = removeMaskImageData.image {
                try await imageAccessor.save(
                  removeMaskImage,
                  frameIndex: frameIndex,
                  as: .removeMask,
                  atSizes: await self.outputSizes,
                  overwrite: true
                )
            } else {
                Log.w("unable to create remove mask image from data")
            }
        }

        if shouldRemove {
            return (shouldRemove, alphaLevels, alphaYAxis)
        } else {
            return (shouldRemove, [], [])
        }
    }
    
    // remove a selected outlier pixel with data from pixels from adjecent frames
    // this uses a pre-computed image of all 'good' pixels merged from a number
    // of star-aligned neighbor frames
    internal func updatePixel(
      x: Int, y: Int,
      alpha: Double,
      toData data: inout ImageBuffer<UInt16>,
      image: PixelatedImage,
      starAlignedImage: PixelatedImage,
      earthAlignedImage: PixelatedImage?,
      horizonMask: PixelatedImage?
    ) {

        guard let horizonMask,
              let earthAlignedImage
        else {
            //Log.d("frame \(frameIndex) updating pixel [\(x), \(y)] as star aligned")
            // use star aligned image because that's all we've been given
            self.updatePixel(x: x, y: y,
                             alpha: alpha,
                             toData: &data,
                             image: image,
                             with: starAlignedImage.readPixel(atX: x, andY: y))
            return
        }
        
        if horizonMask.isMax(atX: x, andY: y) {
            // we are in the sky
            //Log.d("frame \(frameIndex) updating pixel [\(x), \(y)] as sky aligned")
            self.updatePixel(
              x: x, y: y,
              alpha: alpha,
              toData: &data,
              image: image,
              with: starAlignedImage.readPixel(atX: x, andY: y)
            )
        } else {
            // we are in the ground
            //Log.d("frame \(frameIndex) updating pixel [\(x), \(y)] as earth aligned")
            self.updatePixel(
              x: x, y: y,
              alpha: alpha,
              toData: &data,
              image: image,
              with: earthAlignedImage.readPixel(atX: x, andY: y)
            )
        } 
    }

    // remove a selected outlier pixel with data from pixels from adjecent frames
    internal func updatePixel(x: Int, y: Int,
                              alpha: Double,
                              toData data: inout ImageBuffer<UInt16>,
                              image: PixelatedImage,
                              with overwritingPixel: Pixel)
    {
        var overwritingPixel = overwritingPixel
        let op = image.readPixel(atX: x, andY: y)

        //Log.d("frame \(frameIndex) updating pixel @ (\(x), \(y)) from \(op) to \(overwritingPixel) with alpha \(alpha)")
        
        if alpha < 1 {
            // merge in original value
            overwritingPixel = Pixel(merging: overwritingPixel, with: op, atAlpha: alpha)
            //Log.d("frame \(frameIndex) updating pixel @ (\(x), \(y)) overwritingPixel is now \(overwritingPixel) after merge with alpha \(alpha)")
        }

        // the is the place in the image data to write to
        let offset = (Int(y) * image.bytesPerRow/2) + (Int(x) * image.bytesPerPixel/2)

        // actually remove that airplane like thing in the image data
        if self.componentsPerPixel == 1 {
            // one componant per pixel, binary 16 bit image
            data[offset] = overwritingPixel.red
        } else if self.componentsPerPixel == 3 {
            // three componants per pixel, RGB 16 bit image
            data[offset] = overwritingPixel.red
            data[offset+1] = overwritingPixel.green
            data[offset+2] = overwritingPixel.blue
        } else if self.componentsPerPixel == 4 {
            // four componants per pixel, RGBA 16 bit image
            data[offset] = overwritingPixel.red
            data[offset+1] = overwritingPixel.green
            data[offset+2] = overwritingPixel.blue
            data[offset+3] = 0xFFFF
        }
    }


    // Mark - Auto Mode Logic

    /*
     here 'auto processed' means no user interaction at all,
     and no outlier detection, and no subtraction image.
     
     the output image will be a combination of the star and earth aligned
     images, masked with the horizon mask.

     If the sky contains little to no clouds, this approach can work, and gets
     rid of even the small distant satellites that move slowly through the sky.
     */
    func createAutoProcessedImage() async throws -> PixelatedImage? {
        Log.i("frame \(frameIndex) creating auto processed image")

        // Gate on memory — this method loads star-aligned (and possibly earth-aligned)
        // plus the original image, so estimate ~2 full images worth
        let estimatedBytes = MemoryMonitor.estimatedImageBytes(
            width: width,
            height: height,
            componentsPerPixel: componentsPerPixel
        ) * 2
        await MemoryMonitor.shared.waitForMemory(needed: estimatedBytes)

        let result = try await alignmentProcessor.loadOrCreateStarAlignedImage()
        let starAlignedImage = result.warpedFrame

        Log.i("frame \(frameIndex) got result \(result) for star aligned image")

        let config = await configManager.config()
        
        var skyImage: PixelatedImage? = nil
        if let starAlignedImage {
            skyImage = PixelatedImage(mat: starAlignedImage)
        }
        if skyImage == nil {
            // if we don't have a successful sky alignment image,
            // the original looks best for auto processed,
            // load that here
            skyImage = try await imageAccessor.load(
              frameIndex: frameIndex,
              type: .original,
              atSize: .original)
        }

        guard let skyImage else {
            let msg = "frame \(frameIndex) cannot create auto processed image without a star aligned image or an original image"
            Log.e(msg)
            throw msg
        }
        
        if config.horizonDetectionEnabled {
            // with horizon detection, we need to mask the star and earth images

            var earthImage: PixelatedImage? = nil
            var horizonMask: PixelatedImage? = nil

            if config.allowEarthAlignment {
                let alignmentResult = try await alignmentProcessor.loadOrCreateEarthAlignedImage()

                // XXX add check to see if the alignment was good, and if so, save it
                // if not, return early
                
                // XXX validate this alignment result, it might be erroneous
                // if it's bad, use the original frame and horizon mask instead

                let earthAlignedImage = alignmentResult.warpedFrame
                if let mat = alignmentResult.warpedHorizon {
                    horizonMask = PixelatedImage(mat: mat)
                } else {
                    horizonMask = try await horizonProcessor.loadOrCreateFinalHorizonMask()?.image
                }
                
                if let earthAlignedImage {
                    earthImage = PixelatedImage(mat: earthAlignedImage)
                }
            } else {
                // not using earth alignment

                // use original image for the earth
                earthImage = try await imageAccessor.load(
                  frameIndex: frameIndex,
                  type: .original,
                  atSize: .original)

                horizonMask = try await horizonProcessor.loadOrCreateFinalHorizonMask()?.image
            }
            
            if let earthImage {
                if let horizonMask,
                   let highHorizon = horizonMask.shiftImageUp(
                     by: config.horizonVerticalShiftAmount
                   )
                {
                    // this merged horizon mask should have been created right above
                    return try skyImage.apply(
                      mask: highHorizon,
                      with: earthImage
                    )
                } else {
                    // but if not, fallback to the non-merged one, which is better than nothing
                    Log.w("frame \(frameIndex) falling back to non-merged horizon mask")
                    if let horizonMask = try await horizonProcessor.loadOrCreateFinalHorizonMask() {
                        if let highHorizon = horizonMask.image.shiftImageUp(
                             by: config.horizonVerticalShiftAmount
                           ) {
                            return try skyImage.apply(
                              mask: highHorizon,
                              with: earthImage
                            )
                        } else {
                            // we can't extend the horizon, just use what we have
                            return try skyImage.apply(
                              mask: horizonMask.image,
                              with: earthImage
                            )
                        }
                    } else {
                        Log.w("frame \(frameIndex) cannot load or create final horizon mask")
                        return skyImage
                    }
                }
            } else {
                // no earth aligned image, fall back to sky

                // XXX check here to see if there was a horizon mask,
                // and if so, apply it with the original image for earth
                
                return skyImage
            }
        } else {
            // without horizon detection, just return the star aligned image
            return skyImage
        }
    }

    public var usesOutliers: Bool {
        get async {
            await self.cleanMethod.usesOutliers
        }
    }

    public var cleanMethod: CleanMethod {
        get async {
            let config = await configManager.config()
            if let override = config.pixelReplacementOverrides[self.frameIndex] {
                return override
            } else {
                return config.cleanMethod
            }
        }
    }

    public func set(
      cleanMethod: CleanMethod,
      process: Bool = true,
      update: Bool = true
    ) async {

        var hasChanged = false
        
        var config = await configManager.config()
        config.pixelReplacementOverrides[self.frameIndex] = cleanMethod
        if update {
            await MainActor.run {
                configManager.update(config)
            }
        }
        hasChanged = await observer?.cleanMethod == cleanMethod
        await observer?.set(cleanMethod: cleanMethod)

        
        if !process { return }

        if !hasChanged { return }

        // after setting the clean mode on a frame, we need to
        // 1. check to see if there is a processed type for this method
        // 2. create one if not
        // 3. link to the final image

        let outputSizes = await self.outputSizes

        do {
            switch cleanMethod {
            case .automatic(let usesOutliers):
                if usesOutliers {
                    if let filename = imageAccessor.nameForImage(
                         frameIndex: frameIndex,
                         ofType: .autoSelectiveProcessed,
                         atSize: .original
                       )
                    {
                        if FileManager.default.fileExists(atPath: filename) {
                            try await imageAccessor.linkFinals(
                              frameIndex: frameIndex,
                              as: .autoSelectiveProcessed,
                              atSizes: outputSizes
                            )
                        } else {
                            // no file exists
                            try await self.finishAuto(
                              useOutliers: true
                            )
                        }
                    }
                } else {
                    // doesn't use outliers
                    if let filename = imageAccessor.nameForImage(
                         frameIndex: frameIndex,
                         ofType: .autoProcessed,
                         atSize: .original
                       )
                    {
                        if FileManager.default.fileExists(atPath: filename) {
                            try await imageAccessor.linkFinals(
                              frameIndex: frameIndex,
                              as: .autoProcessed,
                              atSizes: outputSizes 
                            )
                        } else {
                            // no file exists
                            try await self.finishAuto(
                              useOutliers: false
                            )
                        }
                    }
                }
            case .selective:
                if let filename = imageAccessor.nameForImage(
                     frameIndex: frameIndex,
                     ofType: .selectiveProcessed,
                     atSize: .original
                   )
                {
                    if FileManager.default.fileExists(atPath: filename) {
                        try await imageAccessor.linkFinals(
                          frameIndex: frameIndex,
                          as: .selectiveProcessed,
                          atSizes: outputSizes
                        )
                    } else {
                        // no file exists

                        try await self.loadOutliers()

                        self.set(state: .secondClassification)

                        // 3. classify outliers
                        await self.applyDecisionTreeToAllOutliers()

                        try await self.finishSelective()

                        await self.updateCombineSubjects()
                    }
                }
            }
        } catch {
            Log.e("error frame \(frameIndex): \(error)")
        }
    }
    
    // used by PixelReplacementMode.automatic
    public func finishAuto(
      useOutliers: Bool
    ) async throws {

        var autoProcessedImage: PixelatedImage? = nil

        let autoAlreadyDone = imageAccessor.imageExists(
          frameIndex: frameIndex,
          ofType: .autoProcessed,
          atSize: .original
        )
        
        if !useOutliers,
           autoAlreadyDone
        {
            Log.i("frame \(frameIndex) auto already done")
            try await imageAccessor.linkFinals(
              frameIndex: frameIndex,
              as: .autoProcessed,
              atSizes: [.original, .preview]
            )
            return
        }

        if useOutliers,
           autoAlreadyDone
        {
            autoProcessedImage = try await imageAccessor.load(
              frameIndex: frameIndex,
              type: .autoProcessed,
              atSize: .original
            )
        }

        if autoProcessedImage == nil {
            autoProcessedImage = try await createAutoProcessedImage()
        }
        
        guard let autoProcessedImage
        else {
            Log.e("frame \(frameIndex) unable to load or create auto processed image")
            return
        }

        if useOutliers {
            // if using outliers, 
            let originalImage =
              try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
            guard let originalImage else {
                Log.e("cannot finish without original image")
                return
            }

            mkdir(await outlierProcessor.outliersDirname)
            
            await outlierProcessor.writeOutliersRemoveReasons()

            self.set(state: .finishing)

            let config = await configManager.config()
            
            if config.writeOutlierClassificationValues {
                // THIS MOFO IS SLOW
                self.set(state: .writingOutlierValues)

                Log.d("frame \(self.frameIndex) finish 1")
                // write out the classifier feature data for this data point
                try await outlierProcessor.writeOutlierValuesCSV()
            }

            Log.d("frame \(self.frameIndex) finish 2")
            if !self.writeOutputFiles {
                Log.d("frame \(self.frameIndex) not writing output files")
                self.set(state: .complete)
                if let completion { await completion() }
                return
            }
            
            Log.i("frame \(self.frameIndex) finishing")

            let format = autoProcessedImage.ensure16Bits.imageData

            switch format {
            case .thirtyTwoBit(_):
                fatalError("frame \(self.frameIndex) cannot load 32 bit image here now")
                
            case .eightBit(_):
                Log.e("8 bit not supported here now")
            case .sixteenBit(let outputData):
                Log.d("frame \(self.frameIndex) replacing airplanes")

                // copy the outputData to a new Buffer
                var newImageBuffer = ImageBuffer<UInt16>(
                  pointer: outputData,
                  width: autoProcessedImage.width,
                  height: autoProcessedImage.height,
                  components: autoProcessedImage.componentsPerPixel
                )
                
                try await self.replaceAirplanes(
                  image: autoProcessedImage,
                  toData: &newImageBuffer,
                  originalImage: originalImage
                )

                if let processedImage = newImageBuffer.image {
                    // write frame out as processed versions
                    do {
                        Log.d("frame \(self.frameIndex) processed file")
                        try await imageAccessor.save(
                          processedImage,
                          frameIndex: frameIndex,
                          as: .autoSelectiveProcessed,
                          atSizes: outputSizes,
                          overwrite: true
                        )

                        // link to final here
                        try await imageAccessor.linkFinals(
                          frameIndex: frameIndex,
                          as: .autoSelectiveProcessed,
                          atSizes: outputSizes
                        )

                    } catch {
                        // XXX for some reason this error gets missed if we don't catch it here :(
                        Log.d("frame \(self.frameIndex) ERROR \(error)")

                    }
                    if let outlierGroups = await outlierProcessor.getOutlierGroups() {
                        Log.d("frame \(self.frameIndex) getting validating image")
                        if let validationImage = await outlierGroups.validationImage() {
                            Log.d("frame \(self.frameIndex) writing validated image")
                            try await imageAccessor.save(
                              validationImage,
                              frameIndex: frameIndex,
                              as: .validation,
                              atSizes: outputSizes,
                              overwrite: false
                            )
                        } else {
                            Log.w("frame \(self.frameIndex) cannot create validation image")
                        }
                    }
                    Log.d("frame \(self.frameIndex) done writing output files")
                }
            }
        } else if !autoAlreadyDone {
            // if not using outliers, then save the auto processed image as
            // complete 
            self.set(state: .loadingImages1)
            try await imageAccessor.save(
              autoProcessedImage, 
              frameIndex: frameIndex,
              as: .autoProcessed,
              atSizes: outputSizes,
              overwrite: false
            )

            // link to final here
            try await imageAccessor.linkFinals(
              frameIndex: frameIndex,
              as: .autoProcessed,
              atSizes: outputSizes
            )
            
            /*
            try await imageAccessor.save(
              autoProcessedImage,
              frameIndex: frameIndex,
              as: .final,
              atSize: .thumbnail,
              overwrite: false
            )*/
            self.set(state: .complete)
            await MemoryMonitor.shared.memoryFreed()
        }
    }


    // Mark - Subtraction

    /*

     Image subtraction logic
     
     */

    // returns a grayscale image pixel value array from subtracting the aligned frames
    // from the frame being processed.
    internal func loadOrCreateSubtractionImage() async throws -> PixelatedImage {
        // first try to load the subtracted image directly from file

        let accessor = imageAccessor
        
        if let image = try await imageAccessor.load(
             frameIndex: frameIndex,
             type: .subtraction,
             atSize: .original)
        {
            return image
        }

        // if we don't have the subtracted image on file yet, make it
        Log.d("frame \(frameIndex) loadOrCreateSubtractionImage")

        // load or create the aligned frame

        Log.d("frame \(frameIndex) loadOrCreateStarAlignedImage")
        let result = try await alignmentProcessor.loadOrCreateStarAlignedImage()
        let starAlignedImage = result.warpedFrame
          
        Log.d("frame \(frameIndex) loadedOrCreatedStarAlignedImage")

        var skyImage: PixelatedImage? = nil

        if let starAlignedImage {
            skyImage = PixelatedImage(mat: starAlignedImage)
        }
//        if skyImage == nil {
//            skyImage = failedStarAlignment
//        }
        guard let skyImage else {
            let msg = "frame \(frameIndex) cannot create subtraction image without either a successful or failed alignment image"
            Log.e(msg)
            throw msg
        }
        
        let config = await configManager.config()

        var subtractionImage: PixelatedImage! = nil

        // subtract the aligned frame
        // result is image - alignedFrame
        // any pixel which is bright in image but not bright in alignedFrames
        // will be bright in the subtractionImage
        //Log.d("frame \(frameIndex) OG image \(image.description)")

        var imageToSubtract: PixelatedImage? = nil
        
        if config.horizonDetectionEnabled {
            Log.d("doing horizon enabled subtraction image")
            // we care about the horizon, so make a composite
            // of the earth and star aligned images, and subtract
            // that from the image instead of just the star aligned image

            let alignmentResult = try await alignmentProcessor.loadOrCreateEarthAlignedImage()
            let earthAlignedImage = alignmentResult.warpedFrame
            let horizonMask = alignmentResult.warpedHorizon

            let earthImage = earthAlignedImage

            if let earthImage,
               let earth = PixelatedImage(mat: earthImage)
            {
                if let horizonMask,
                   let horizon = PixelatedImage(mat: horizonMask)
                {
                    imageToSubtract = try skyImage.apply(
                      mask: horizon,
                      with: earth
                    )
                } else if let mask = try await horizonProcessor.loadOrCreateFinalHorizonMask() {
                    // fall back to non merged horizon mask if we have to
                    imageToSubtract = try skyImage.apply(
                      mask: mask.image,
                      with: earth
                    )
                }
            } else {
                // with no earth image to use, fall back to the sky
                imageToSubtract = skyImage
            }
            
        } else {
            // with no horizon to worry about, just subtract the star aligned image
            
            imageToSubtract = skyImage
        }


        if let imageToSubtract {

            // load the original
            guard let image = try await accessor.load(
                    frameIndex: frameIndex,
                    type: .original,
                    atSize: .original)
            else {
                Log.e("frame \(frameIndex) couldn't load original image")
                // XXX these should really throw an error, and that really should
                // be handled properly at a higher level, but right now, thrown errors
                // from here end up in the bitbucket :(  Need to figure out why
                throw "frame \(frameIndex) couldn't original image"
            }
            Log.d("frame \(frameIndex) got orig image \(image.description)")
            

            subtractionImage = try image.subtract(imageToSubtract)

            if config.writeOutlierGroupFiles {
                // write out image of outlier amounts
                do {
                    try await accessor.save(subtractionImage,
                                            frameIndex: frameIndex,
                                            as: .subtraction,
                                            atSize: .original,
                                            overwrite: true)
                    try await accessor.save(subtractionImage,
                                            frameIndex: frameIndex,
                                            as: .subtraction,
                                            atSize: .preview,
                                            overwrite: true)
                } catch {
                    Log.e("frame \(frameIndex) can't write subtraction image: \(error)")
                }
            }

            return subtractionImage
        } else {
            throw "unable to create image to subtract"
        }
    }

}



/// Removes *only* the files in the specified directory URL (non‐recursive)
/// whose filenames end with the given suffix. Subdirectories (and their
/// contents) are left untouched.
/// - Parameters:
///   - suffix: the filename suffix to match (e.g. ".txt" or "log").
///   - directoryURL: the URL of an existing directory
/// - Throws: any FileManager errors encountered during listing or removal
func removeFiles(withSuffix suffix: String, in directoryPath: String) throws {
    let fm = FileManager.default

    let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

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

        // Only remove files whose name ends with the given suffix
        let fileName = fileURL.lastPathComponent
        guard fileName.hasSuffix(suffix) else { continue }

        // Remove the file
        try fm.removeItem(at: fileURL)
    }
}

public actor CountActor {
    private var value: Int = 0

    public init() {
        value = 0
    }
    
    public func increase() { value += 1 }
    public func decrease() { value -= 1 }
    
    public func isMore(than: Int) -> Bool { value > than }
    public func isMoreThanZero() -> Bool { value > 0 }
}


// OCVFeatureSet is already @unchecked Sendable in StarCppBridge

public func doublyLink(frames: [FrameAirplaneRemover]) async {
    // doubly link frames here so that the decision tree can have acess to other frames
    for (i, frame) in frames.enumerated() {
        if await frames[i].getPreviousFrame() == nil,
           i > 0
        {
            await frame.setPreviousFrame(frames[i-1])
        }
        if await frames[i].getNextFrame() == nil,
           i < frames.count - 1
        {
            await frame.setNextFrame(frames[i+1])
        }
    }
}
