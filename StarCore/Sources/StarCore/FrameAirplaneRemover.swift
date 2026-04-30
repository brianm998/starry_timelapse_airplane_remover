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
            if let results = await self.readEarthNeighborHomographyForThisFrame() {
                //Log.d("frame \(frameIndex) setting number of earth alignments \(results)")
                await observer.set(earthAlignmentResults: results)
            } else {
                //Log.d("frame \(frameIndex) NO number of earth alignments")
            }

            if let results = await self.readStarNeighborHomographyForThisFrame() {
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
    nonisolated public let componentsPerPixel: Int
    nonisolated public let frameIndex: Int

    // populated by pruning
    public var outlierGroups: OutlierGroups? // XXX LOTS OF MEMORY ???

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
    
    internal var isLoadingOutliers = false

    private weak var imageSequence: ImageSequence?

    private var skyKeyPoints: OCVFeatureSet? = nil {
        didSet {
            Log.d("frame \(frameIndex) did set skyKeyPoints \(skyKeyPoints as Any)")
            Task { 
                await observer?.set(numberOfSkyKeyPoints: self.skyKeyPointCount())
            }
        }
    }
    private var earthKeyPoints: OCVFeatureSet? = nil {
        didSet {
            Task {
                await observer?.set(numberOfEarthKeyPoints: self.earthKeyPointCount())
            }
        }
    }

    public func skyKeyPointCount() -> Int {
        if let skyKeyPoints {
            skyKeyPoints.keypointCount
        } else {
            0
        }
    }
    
    public func earthKeyPointCount() -> Int {
        if let earthKeyPoints {
            earthKeyPoints.keypointCount
        } else {
            0
        }
    }
    
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

        // call directly in init becuase didSet() isn't called from here :P
       
        //Log.d("config.numberAlignedNeighborFrames \(config.numberAlignedNeighborFrames)")
        await self.setNumberOfAlignedFrames(with: initialConfig)
        await self.setNumberOfStaticNeighborFrames(with: initialConfig)
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
        } else if FileManager.default.fileExists(atPath: "\(await self.outliersDirname)/\(BlobBinarySaver.outlierBinaryFilename)") {
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

    public func setNumberOfStaticNeighborFrames(with config: Config? = nil) async {
        if let config {
            self.staticNeighborFrames = calculateNeighborIndices(config.numberStaticNeighborFrames(for: frameIndex))
        } else {
            let config = await configManager.config()
            self.staticNeighborFrames = calculateNeighborIndices(config.numberStaticNeighborFrames(for: frameIndex))
        }
    }

    /// If the merged horizon has already been computed for this frame, deletes the
    /// cached image and recomputes it using the current staticNeighborFrames count.
    /// Call this after changing the per-frame staticNeighborFrames override so that
    /// already-processed frames get an updated merged horizon without a full reprocess.
    public func recomputeMergedHorizonIfExists() async throws {
        guard imageAccessor.imageExists(
          frameIndex: frameIndex,
          ofType: .mergedHorizon,
          atSize: .original
        ) else { return }
        imageAccessor.deleteImages(
          frameIndex: frameIndex,
          ofTypes: [.mergedHorizon],
          atSizes: [.original, .preview]
        )
        _ = try await loadOrCreateFinalHorizonMask()
    }
          
    public func setNumberOfAlignedFrames(with config: Config? = nil) async {
        if let config {
            self.alignmentFrames = calculateNeighborIndices(config.numberAlignedNeighborFrames(for: frameIndex))
        } else {
            let config = await configManager.config()
            self.alignmentFrames = calculateNeighborIndices(config.numberAlignedNeighborFrames(for: frameIndex))
        }
        Log.d("frame \(frameIndex) set alignedNeighborFrames \(self.alignmentFrames)")
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
        try removeNumberOfAlignedImagesForThisFrameFile()
        try removeNeighborStarHomography()
        // Clear in-memory homography caches so reprocessing recomputes them
        // rather than reusing the stale cached values.
        self.neighborStarHomography = nil
        self.neighborEarthHomography = nil
        self.state = .unprocessed
        return true
    }
    
    public func calculateNeighborIndices(_ alignmentNumber: Int) -> [Int] {
        Log.d("frame \(frameIndex) calculateNeighborIndices(alignmentNumber: \(alignmentNumber))")
        guard let imageSequence else {
            Log.e("cannot set number of alignment images without an image sequence")
            return []
        }
        if alignmentNumber < 1 {
            Log.e("invalid alignmentNumbernumberOfImage \(alignmentNumber)")
            return []
        }

        var halfNumber = alignmentNumber/2
        if alignmentNumber % 2 == 1 { halfNumber += 1 } // round up

        var startFrame = frameIndex - halfNumber
        var endFrame = startFrame + alignmentNumber + 1
        
        if startFrame < 0 { startFrame = 0 }
        if endFrame >= imageSequence.filenames.count {
            endFrame = imageSequence.filenames.count - 1
        }
        
        var ret: [Int] = []
        
        // calculate the frame indicies of the frames we will use for star alignment
        for index in startFrame..<endFrame {
            if index == frameIndex { continue }
            ret.append(index)
        }

        //Log.d("frame \(frameIndex) has alignment frames \(ret)")

        return ret
    }

    public var numberOfAlignedFrames: Int { alignmentFrames.count }

    internal func loadOrCreateFinalHorizonMask() async throws -> HorizonMask? {
        if let mask = try await self.loadOrCreateMergedHorizonMask() {
            mask
        } else {
            // fall back to non-merged horizon mask
            try await self.loadOrCreateHorizonMask()
        }
    }
    
    // this horizon mask has been calculated by a median merge of
    // possibly aligned horizon masks from neighbor frames.
    public func loadOrCreateMergedHorizonMask() async throws -> HorizonMask? {
        // If the user has painted a reference horizon, use it directly.
        if let referenceMask = try await loadHorizonReferenceMask() {
            Log.i("frame \(frameIndex) loadOrCreateMergedHorizonMask: using reference mask (skipping merge)")
            return referenceMask
        }
        Log.d("frame \(frameIndex) trying to load merged horizon mask")
        // load if possible
        do {
            if let horizonMaskImage = try await imageAccessor.load(
                 frameIndex: frameIndex,
                 type: .mergedHorizon,
                 atSize: .original
               )
            {
                Log.d("frame \(frameIndex) successfully loaded merged horizon mask")

                if let bounds = horizonMaskImage.horizonBounds() {
                    return HorizonMask(
                      image: horizonMaskImage,
                      horizonTopY: bounds.topY,
                      horizonBottomY: bounds.bottomY
                    )
                }
                Log.w("frame \(frameIndex) loaded merged horizon mask image but could not compute bounds")
            }
        } catch {
            Log.w("frame \(frameIndex) unable to load merged horizon mask")
        }

        Log.i("frame \(frameIndex) making merged horizon")

        return try await createMergedHorizonMask()
    }

    public func getHorizonMergeIndices() async -> [Int] {
        let config = await configManager.config()
        if config.tripodHeadWasMoving {
            return alignmentFrames
        } else {
            return staticNeighborFrames
        }
    }
    
    public func createMergedHorizonMask() async throws -> HorizonMask? {

        self.set(state: .mergingHorizon)

        // get original horizon mask for this frame
        Log.d("frame \(frameIndex) calling loadOrCreateHorizonMask()")
        let mask = try await self.loadOrCreateHorizonMask()

        let config = await configManager.config()

        // Reference-horizon smoothing pass (moving sequences only).
        // When enabled and a user-defined reference horizon exists within
        // referenceHorizonSmoothingMaxDistance frames, use it to filter
        // statistically implausible column values and save as merged horizon.
        if config.useReferenceHorizonSmoothing,
           config.tripodHeadWasMoving,
           let (_, refMask) = try await nearestReferenceHorizon(
             maxDistance: config.referenceHorizonSmoothingMaxDistance
           )
        {
            Log.i("frame \(frameIndex) createMergedHorizonMask: applying reference-horizon smoothing")
            if let filtered = referenceSmoothedHorizonMask(detected: mask, reference: refMask) {
                let finalMask = try await referenceStatsBrightnessRefinementIfNeeded(
                  mask: filtered,
                  config: config
                )
                try await imageAccessor.save(
                  finalMask.image,
                  frameIndex: frameIndex,
                  as: .mergedHorizon,
                  atSizes: await self.outputSizes,
                  overwrite: true
                )
                return finalMask
            }
            Log.w("frame \(frameIndex) reference smoothing failed, falling through to normal merge")
        }

        var neighborIndices: [Int] = []

        if config.tripodHeadWasMoving {
            neighborIndices = await self.getHorizonMergeIndices()
        } else {
            // static video uses all frames
            if let imageSequence {
                neighborIndices = Array(0..<imageSequence.filenames.count)
            } else {
                Log.w("cannot get static neighbor indices without an image sequence")
            }
        }
        
        // get the names of neighboring horizon masks
        let neighboringHorizons = neighborIndices.compactMap {
            self.imageAccessor.nameForImage(frameIndex: $0,
                                            ofType: .horizon,
                                            atSize: .original)
        }

        Log.i("frame \(frameIndex) making merged horizon \(staticNeighborFrames.count) staticNeighborFrames \(neighboringHorizons.count) neighboringHorizons")
        
        if let mergedHorizon = mask.image.medianMerge(
             with: neighboringHorizons,
             outlierThreshold: await self.pixelThreshold,
             includeAll: true)
        {
            // Apply stats-based brightness refinement for moving sequences.
            let imageToSave: PixelatedImage
            if config.tripodHeadWasMoving,
               let mergedMask = HorizonMask(mergedHorizon),
               let refined = try? await referenceStatsBrightnessRefinementIfNeeded(
                 mask: mergedMask,
                 config: config
               )
            {
                imageToSave = refined.image
            } else {
                imageToSave = mergedHorizon
            }

            Log.d("saving merged horizon images")
            try await imageAccessor.save(
              imageToSave,
              frameIndex: frameIndex,
              as: .mergedHorizon,
              atSizes: await self.outputSizes,
              overwrite: true
            )
            if !config.tripodHeadWasMoving {
                // for static videos link all the merged horizons together here
                for size in await self.outputSizes {
                    if let fromName = imageAccessor.nameForImage(
                         frameIndex: frameIndex,
                         ofType: .mergedHorizon,
                         atSize: size
                       )
                    {
                        for neighborIndex in neighborIndices {
                            if neighborIndex != frameIndex {
                                if let toName = imageAccessor.nameForImage(
                                     frameIndex: neighborIndex,
                                     ofType: .mergedHorizon,
                                     atSize: size
                                   )
                                {
                                    do {
                                        try createHardLinkReplacingDestination(
                                          from: fromName,
                                          to: toName
                                        )
                                    } catch {
                                        Log.w("cannot hard link \(fromName) to \(toName), trying copy")
                                        try copyReplacingDestination(
                                          from: fromName,
                                          to: toName
                                        )
                                    }
                                } else {
                                    Log.w("unable to get name for merged horizon for frameIndex \(neighborIndex)")
                                }
                            }
                        }
                    } else {
                        Log.w("unable to get name for merged horizon for frameIndex \(frameIndex)")
                    }
                }
            }
            
            if let bounds = imageToSave.horizonBounds() {
                return HorizonMask(
                  image: imageToSave,
                  horizonTopY: bounds.topY,
                  horizonBottomY: bounds.bottomY
                )
            }
            Log.w("frame \(frameIndex) merged horizon has no computable bounds")
        }

        Log.w("frame \(frameIndex) unable to calculate merged horizon")
        
        return nil
    }

    // MARK: - Reference horizon smoothing helpers

    /// Returns the (frameIndex, mask) of the nearest user-defined reference horizon
    /// within `maxDistance` frames of the current frame, or nil if none exists.
    private func nearestReferenceHorizon(
      maxDistance: Int
    ) async throws -> (Int, HorizonMask)? {
        guard let imageSequence else { return nil }
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else { return nil }

        let referenceDir = URL(fileURLWithPath: refinedPath)
            .deletingLastPathComponent()    // …/refinedHorizon
            .deletingLastPathComponent()    // …/output
            .appendingPathComponent("horizonReference")

        let fm = FileManager.default
        var bestDistance = Int.max
        var bestIndex: Int = -1
        var bestMask: HorizonMask? = nil

        let frameCount = imageSequence.filenames.count
        for candidateIndex in 0..<frameCount {
            let distance = abs(candidateIndex - frameIndex)
            guard distance <= maxDistance, distance < bestDistance else { continue }

            // Derive the reference filename the same way loadHorizonReferenceMask does:
            // use the refinedHorizon path for the candidate frame, take its last component.
            guard let candidatePath = imageAccessor.nameForImage(
                    frameIndex: candidateIndex,
                    ofType: .refinedHorizon,
                    atSize: .original
                  )
            else { continue }
            let candidateFileName = URL(fileURLWithPath: candidatePath).lastPathComponent
            let candidateRefURL = referenceDir.appendingPathComponent(candidateFileName)

            guard fm.fileExists(atPath: candidateRefURL.path),
                  let img = PixelatedImage(filename: candidateRefURL.path)?.asHorizonMask,
                  let horizonMask = HorizonMask(img)
            else { continue }

            bestDistance = distance
            bestIndex = candidateIndex
            bestMask = horizonMask
        }

        guard let mask = bestMask else { return nil }
        return (bestIndex, mask)
    }

    /// Filter a detected horizon mask using a reference mask to reject per-column
    /// Y values that are statistical outliers relative to the reference.
    ///
    /// For each column the delta between detected and reference horizon Y is computed.
    /// Columns whose delta deviates more than 2 standard deviations from the mean
    /// delta are replaced by the reference Y value.  This removes obviously wrong
    /// detections without clamping the entire mask to the reference.
    private func referenceSmoothedHorizonMask(
      detected: HorizonMask,
      reference: HorizonMask
    ) -> HorizonMask? {
        let w = detected.image.width
        let h = detected.image.height

        let detectedY  = HorizonScoring.extractHorizonYPerColumn(from: detected.image)
        let referenceY = HorizonScoring.extractHorizonYPerColumn(from: reference.image)

        // Compute per-column deltas where both masks have a defined horizon Y.
        var deltas: [Double] = []
        for x in 0..<w {
            if let dy = detectedY[x], let ry = referenceY[x] {
                deltas.append(Double(dy - ry))
            }
        }

        guard !deltas.isEmpty else {
            Log.w("frame \(frameIndex) referenceSmoothedHorizonMask: no common columns, skipping")
            return nil
        }

        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let variance = deltas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(deltas.count)
        let stddev = variance.squareRoot()
        let threshold = 2.0 * max(stddev, 1.0) // at least 1 px to avoid clamping tiny natural variation

        Log.d("frame \(frameIndex) referenceSmoothedHorizonMask: mean delta=\(String(format:"%.1f", mean)) stddev=\(String(format:"%.1f", stddev)) threshold=\(String(format:"%.1f", threshold))")

        // Build corrected per-column Y array.
        var correctedY = detectedY
        var replacedCount = 0
        for x in 0..<w {
            guard let dy = detectedY[x] else { continue }
            let ry = referenceY[x]
            let delta = Double(dy) - Double(ry ?? dy)
            if abs(delta - mean) > threshold, let refY = ry {
                correctedY[x] = refY
                replacedCount += 1
            }
        }

        Log.i("frame \(frameIndex) referenceSmoothedHorizonMask: replaced \(replacedCount)/\(w) columns")

        guard let maskImage = PixelatedImage.fromHorizonColumnY(width: w, height: h, columnY: correctedY),
              let result = HorizonMask(maskImage)
        else {
            Log.w("frame \(frameIndex) referenceSmoothedHorizonMask: failed to build mask image")
            return nil
        }

        return result
    }

    // MARK: - Reference stats brightness refinement

    /// Scan the sequence for reference horizon masks, return stats for up to `maxCount`
    /// nearest frames.  Stats are cached in `referenceHorizonStatsCache`.
    private func referenceHorizonsWithStats(maxCount: Int = 2) async throws -> [ReferenceHorizonFrameStats] {
        guard let imageSequence else { return [] }
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else { return [] }

        let referenceDir = URL(fileURLWithPath: refinedPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("horizonReference")

        let fm = FileManager.default
        var candidates: [(distance: Int, index: Int, maskURL: URL)] = []

        for candidateIndex in 0..<imageSequence.filenames.count {
            guard candidateIndex != frameIndex else { continue }
            guard let candidatePath = imageAccessor.nameForImage(
                    frameIndex: candidateIndex,
                    ofType: .refinedHorizon,
                    atSize: .original
                  )
            else { continue }
            let candidateFileName = URL(fileURLWithPath: candidatePath).lastPathComponent
            let candidateURL = referenceDir.appendingPathComponent(candidateFileName)
            guard fm.fileExists(atPath: candidateURL.path) else { continue }
            candidates.append((
                distance: abs(candidateIndex - frameIndex),
                index: candidateIndex,
                maskURL: candidateURL
            ))
        }

        candidates.sort { $0.distance < $1.distance }

        var result: [ReferenceHorizonFrameStats] = []
        for candidate in candidates.prefix(maxCount) {
            if let cached = await referenceHorizonStatsCache.stats(for: candidate.index) {
                result.append(cached)
                continue
            }
            guard let maskImage = PixelatedImage(filename: candidate.maskURL.path)?.asHorizonMask,
                  let mask = HorizonMask(maskImage),
                  let original = try? await imageAccessor.load(
                    frameIndex: candidate.index,
                    type: .original,
                    atSize: .original
                  )
            else {
                Log.w("frame \(frameIndex) referenceHorizonsWithStats: skipping frame \(candidate.index)")
                continue
            }
            guard let stats = original.computeReferenceHorizonStats(frameIndex: candidate.index, mask: mask)
            else { continue }
            await referenceHorizonStatsCache.set(stats)
            result.append(stats)
        }
        return result
    }

    /// Per-pixel brightness + Y-position refinement of `detected` using reference frame stats.
    ///
    /// For each pixel in a band around the widest horizon Y bounds of the reference frames,
    /// the sky/ground decision is driven primarily by brightness:
    ///   - Within [globalMinY, globalMaxY]: brightness alone decides (Y position is neutral
    ///     here because mountain peaks and dips mean position alone is unreliable).
    ///   - Outside that band: a Y-position score is blended in with a weight that grows
    ///     quadratically with distance from the band edge, capped at 0.5 so brightness
    ///     always has the majority influence.
    ///
    /// Pixels with a combined score >= 0.5 are sky; below 0.5 are ground.
    /// Pixels outside the search band are copied unchanged from `detected`.
    private func referenceStatsBrightnessRefinedHorizonMask(
      detected: HorizonMask,
      original: PixelatedImage,
      stats: [ReferenceHorizonFrameStats],
      searchRadius: Int = 100
    ) -> HorizonMask? {
        guard !stats.isEmpty else { return nil }

        let w = detected.image.width
        let h = detected.image.height

        // Compute inverse-distance-weighted brightness medians.
        var totalWeight = 0.0
        var weightedSky = 0.0
        var weightedGround = 0.0
        for s in stats {
            let d = max(1.0, Double(abs(s.frameIndex - frameIndex)))
            let wt = 1.0 / d
            totalWeight    += wt
            weightedSky    += wt * s.medianSkyBrightness
            weightedGround += wt * s.medianGroundBrightness
        }
        let medianSky    = weightedSky    / totalWeight
        let medianGround = weightedGround / totalWeight
        let midBrightness = (medianSky + medianGround) / 2.0
        let halfRange     = abs(medianSky - medianGround) / 2.0
        let skyIsBrighter = medianSky > medianGround

        // Global horizon Y bounds across all reference frames.
        let globalMinY = stats.map { $0.minHorizonY }.min()!
        let globalMaxY = stats.map { $0.maxHorizonY }.max()!
        let bandTop    = max(0,     globalMinY - searchRadius)
        let bandBottom = min(h - 1, globalMaxY + searchRadius)

        guard case .eightBit(let detectedBuf) = detected.image.imageData else {
            Log.w("frame \(frameIndex) referenceStatsBrightnessRefinedHorizonMask: mask not 8-bit")
            return nil
        }

        let maxVal = original.maxBrightnessValue
        var outputBytes = [UInt8](detectedBuf)

        var refinedCount = 0
        let bandRange = Double(max(1, searchRadius))
        for y in bandTop...bandBottom {
            // Within [globalMinY, globalMaxY] rely on brightness alone — the Y range
            // only tells us the horizon could be anywhere in here, so position gives
            // no useful signal.  Outside the band, blend in a Y-position score whose
            // weight grows quadratically with distance from the band edge, capped at
            // 0.5 so brightness always has the majority influence.
            let yWeight: Double
            let ySkyScore: Double
            if y < globalMinY {
                let t = min(1.0, Double(globalMinY - y) / bandRange)
                yWeight   = 0.5 * t * t
                ySkyScore = 1.0
            } else if y > globalMaxY {
                let t = min(1.0, Double(y - globalMaxY) / bandRange)
                yWeight   = 0.5 * t * t
                ySkyScore = 0.0
            } else {
                yWeight   = 0.0
                ySkyScore = 0.5  // unused — pure brightness within the reference band
            }

            for x in 0..<w {
                let brightness = original.normalizedBrightness(x: x, y: y, maxVal: maxVal)

                // Brightness sky score: cubic-weighted distance from midpoint.
                let brightnessSkyScore: Double
                if halfRange < 0.001 {
                    brightnessSkyScore = 0.5  // indistinguishable sky/ground brightnesses
                } else {
                    var normalised = (brightness - midBrightness) / halfRange  // [-1, 1]
                    normalised = max(-1.0, min(1.0, normalised))
                    if !skyIsBrighter { normalised = -normalised }
                    let strong = normalised * normalised * normalised
                    brightnessSkyScore = (strong + 1.0) / 2.0
                }

                let combined = yWeight < 0.001
                    ? brightnessSkyScore
                    : (1.0 - yWeight) * brightnessSkyScore + yWeight * ySkyScore
                let newVal: UInt8 = combined >= 0.5 ? 255 : 0
                let idx = y * w + x
                if newVal != detectedBuf[idx] { refinedCount += 1 }
                outputBytes[idx] = newVal
            }
        }

        Log.i("frame \(frameIndex) referenceStatsBrightnessRefinedHorizonMask: " +
              "refined \(refinedCount) pixels in band y=[\(bandTop),\(bandBottom)] " +
              "globalY=[\(globalMinY),\(globalMaxY)] " +
              "sky=\(String(format:"%.4f",medianSky)) " +
              "ground=\(String(format:"%.4f",medianGround))")

        return outputBytes.withUnsafeMutableBytes { ptr -> HorizonMask? in
            guard let base = ptr.baseAddress else { return nil }
            let mat = MatWrapper(
              width: w, height: h,
              cvType: 0,
              bytesPerRow: w,
              data: base,
              takeOwnership: false
            )
            guard let maskImage = PixelatedImage(mat: mat.clone()) else { return nil }
            return HorizonMask(maskImage)
        }
    }

    /// Apply `referenceStatsBrightnessRefinedHorizonMask` if the config enables it and
    /// reference stats are available.  Returns the original mask unchanged on failure.
    private func referenceStatsBrightnessRefinementIfNeeded(
      mask: HorizonMask,
      config: Config
    ) async throws -> HorizonMask {
        guard config.tripodHeadWasMoving,
              config.useReferenceHorizonBrightnessRefinement
        else { return mask }

        let stats = try await referenceHorizonsWithStats(maxCount: 2)
        guard !stats.isEmpty else { return mask }

        guard let original = try? await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            Log.w("frame \(frameIndex) referenceStatsBrightnessRefinementIfNeeded: cannot load original")
            return mask
        }

        return referenceStatsBrightnessRefinedHorizonMask(
          detected: mask,
          original: original,
          stats: stats,
          searchRadius: config.referenceHorizonBrightnessRefinementSearchRadius
        ) ?? mask
    }

    // MARK: - Refined horizon mask (homography-based refinement)

    /// Load (or create) the refined horizon mask for this frame.
    ///
    /// If a user-painted reference mask exists it is returned immediately and
    /// the tuner is given a chance to update `tuned_parameters.json`.
    /// Otherwise the cached `.refinedHorizon` image is used, falling back to
    /// `createRefinedHorizonMask()`.
    public func loadOrCreateRefinedHorizonMask() async throws -> HorizonMask? {
        // Reference mask takes priority over everything.
        if let referenceMask = try await loadHorizonReferenceMask() {
            Log.i("frame \(frameIndex) loadOrCreateRefinedHorizonMask: using reference mask")
            await maybeTuneHorizonParameters(referenceMask: referenceMask)
            return referenceMask
        }

        // Try the cached refined mask from a previous run.
        do {
            if let image = try await imageAccessor.load(
                 frameIndex: frameIndex,
                 type: .refinedHorizon,
                 atSize: .original
               )
            {
                Log.d("frame \(frameIndex) loadOrCreateRefinedHorizonMask: loaded cached mask")
                return HorizonMask(image)
            }
        } catch {
            Log.w("frame \(frameIndex) loadOrCreateRefinedHorizonMask: cache load failed: \(error)")
        }

        return try await createRefinedHorizonMask()
    }

    /// Look for a user-painted reference horizon mask on disk and return it if found.
    ///
    /// Search order:
    /// 1. `{horizonReference}/{frameFileName}` — per-frame reference (moving sequences)
    /// 2. `{horizonReference}/reference.tiff`   — global reference (static sequences)
    private func loadHorizonReferenceMask() async throws -> HorizonMask? {
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else { return nil }

        let refinedURL      = URL(fileURLWithPath: refinedPath)
        let frameFileName   = refinedURL.lastPathComponent
        let referenceDir    = refinedURL
            .deletingLastPathComponent()    // …/refinedHorizon
            .deletingLastPathComponent()    // …/output (tempOutputPath)
            .appendingPathComponent("horizonReference")

        // 1. Per-frame reference
        let frameRefURL = referenceDir.appendingPathComponent(frameFileName)
        if FileManager.default.fileExists(atPath: frameRefURL.path),
           let refImage = PixelatedImage(filename: frameRefURL.path)?.asHorizonMask
        {
            Log.d("frame \(frameIndex) loadHorizonReferenceMask: found per-frame reference")
            return HorizonMask(refImage)
        }

        // 2. Global reference
        let globalRefURL = referenceDir.appendingPathComponent("reference.tiff")
        if FileManager.default.fileExists(atPath: globalRefURL.path),
           let refImage = PixelatedImage(filename: globalRefURL.path)?.asHorizonMask
        {
            Log.d("frame \(frameIndex) loadHorizonReferenceMask: found global reference")
            return HorizonMask(refImage)
        }

        return nil
    }

    /// Create the refined horizon mask using the homography-based two-pass detector.
    ///
    /// Loads tuned parameters from `tuned_parameters.json` when available.
    internal func createRefinedHorizonMask() async throws -> HorizonMask? {
        self.set(state: .refiningHorizon)

        // Gate on memory — horizon refinement loads neighbor images
        let estimatedBytes = MemoryMonitor.estimatedImageBytes(
            width: width,
            height: height,
            componentsPerPixel: 1,  // horizon masks are single-channel 8-bit
            bytesPerComponent: 1
        )
        await MemoryMonitor.shared.waitForMemory(needed: estimatedBytes)

        // Ensure we have homography results.
        var homographyResults = neighborStarHomography
        if homographyResults == nil {
            homographyResults = await readStarNeighborHomographyForThisFrame()
        }
        guard let homographyResults else {
            Log.w("frame \(frameIndex) createRefinedHorizonMask: no star homography — falling back to merged")
            return try await loadOrCreateMergedHorizonMask()
        }

        // We need the merged horizon mask as the Pass-1 baseline.
        guard let mergedMask = try await loadOrCreateMergedHorizonMask() else { return nil }

        let currentWidth  = mergedMask.image.width
        let currentHeight = mergedMask.image.height

        // Collect valid neighbours that have a homography and original images.
        var neighborHorizonFilenames:   [String]   = []
        var neighborOriginalFilenames:  [String]   = []
        var neighborHomographies:       [[Double]] = []

        for warpInfo in homographyResults.neighborHomography {
            guard warpInfo.alignmentState == .homographySuccess ||
                  warpInfo.alignmentState == .usedExistingHomography,
                  let homography = warpInfo.homography
            else { continue }

            let neighborIndex = warpInfo.frameIndex
            guard let origFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex,
                    ofType: .original,
                    atSize: .original
                  ),
                  let horizFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex,
                    ofType: .mergedHorizon,
                    atSize: .original
                  )
            else { continue }

            neighborOriginalFilenames.append(origFilename)
            neighborHorizonFilenames.append(horizFilename)
            neighborHomographies.append(homography)
        }

        guard !neighborHomographies.isEmpty else {
            Log.w("frame \(frameIndex) createRefinedHorizonMask: no valid neighbours — returning merged mask")
            self.set(state: .horizonRefined)
            return mergedMask
        }

        // Load the current frame's original image for Pass 2.
        let currentImage = try await imageAccessor.load(
            frameIndex: frameIndex,
            type: .original,
            atSize: .original
        )

        // Build the detector and apply any saved tuned parameters.
        var detector = HomographyHorizonDetector()
        if let paramsDir = tunedParametersDirectory(),
           let params = HorizonTunedParameters.load(fromDirectory: paramsDir)
        {
            detector.apply(params)
            Log.i("frame \(frameIndex) createRefinedHorizonMask: applied tuned parameters (MAE: \(params.tuningMeanAbsoluteError.map { String(format: "%.1f", $0) } ?? "n/a"))")
        }

        // Stage 1: expensive I/O.
        let prepared = detector.prepare(
            currentWidth:              currentWidth,
            currentHeight:             currentHeight,
            neighborHorizonFilenames:  neighborHorizonFilenames,
            neighborOriginalFilenames: neighborOriginalFilenames,
            neighborHomographies:      neighborHomographies,
            currentImage:              currentImage
        )

        // Stage 2: fast boundary scan.
        guard let refinedMask = detector.detectFromPrepared(prepared) else {
            Log.w("frame \(frameIndex) createRefinedHorizonMask: detector returned nil — returning merged mask")
            self.set(state: .horizonRefined)
            return mergedMask
        }

        // Save for future runs.
        try await imageAccessor.save(
            refinedMask.image,
            frameIndex: frameIndex,
            as: .refinedHorizon,
            atSizes: await self.outputSizes,
            overwrite: true
        )

        self.set(state: .horizonRefined)
        Log.i("frame \(frameIndex) createRefinedHorizonMask: refined mask created")
        return refinedMask
    }

    // MARK: - Horizon parameter tuning

    /// Returns the URL of the `horizonReference/` directory for this sequence,
    /// or `nil` if the path cannot be determined.
    private func tunedParametersDirectory() -> URL? {
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else { return nil }
        return URL(fileURLWithPath: refinedPath)
            .deletingLastPathComponent()    // …/refinedHorizon
            .deletingLastPathComponent()    // …/output
            .appendingPathComponent("horizonReference")
    }

    /// If `tuned_parameters.json` does not already exist, run coordinate-descent
    /// tuning against `referenceMask` and write the winner.
    private func maybeTuneHorizonParameters(referenceMask: HorizonMask) async {
        guard let paramsDir = tunedParametersDirectory() else { return }

        // Don't overwrite hand-tuned or previously auto-tuned parameters.
        let jsonURL = paramsDir.appendingPathComponent(HorizonTunedParameters.jsonFilename)
        guard !FileManager.default.fileExists(atPath: jsonURL.path) else {
            Log.d("frame \(frameIndex) maybeTuneHorizonParameters: tuned_parameters.json already exists — skipping")
            return
        }

        // Need homography results for prepare().
        var homographyResults = neighborStarHomography
        if homographyResults == nil {
            homographyResults = await readStarNeighborHomographyForThisFrame()
        }
        guard let homographyResults else {
            Log.w("frame \(frameIndex) maybeTuneHorizonParameters: no star homography — cannot tune")
            return
        }

        guard let mergedMask = try? await loadOrCreateMergedHorizonMask() else { return }
        let currentWidth  = mergedMask.image.width
        let currentHeight = mergedMask.image.height

        var neighborHorizonFilenames:   [String]   = []
        var neighborOriginalFilenames:  [String]   = []
        var neighborHomographies:       [[Double]] = []

        for warpInfo in homographyResults.neighborHomography {
            guard warpInfo.alignmentState == .homographySuccess ||
                  warpInfo.alignmentState == .usedExistingHomography,
                  let homography = warpInfo.homography
            else { continue }
            let neighborIndex = warpInfo.frameIndex
            guard let origFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex, ofType: .original, atSize: .original),
                  let horizFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex, ofType: .mergedHorizon, atSize: .original)
            else { continue }
            neighborOriginalFilenames.append(origFilename)
            neighborHorizonFilenames.append(horizFilename)
            neighborHomographies.append(homography)
        }

        guard !neighborHomographies.isEmpty else { return }

        let currentImage = try? await imageAccessor.load(
            frameIndex: frameIndex, type: .original, atSize: .original
        )

        // Prepare once — the expensive I/O stage.
        let seedDetector = HomographyHorizonDetector()
        let prepared = seedDetector.prepare(
            currentWidth:              currentWidth,
            currentHeight:             currentHeight,
            neighborHorizonFilenames:  neighborHorizonFilenames,
            neighborOriginalFilenames: neighborOriginalFilenames,
            neighborHomographies:      neighborHomographies,
            currentImage:              currentImage
        )

        let referenceY = HomographyHorizonDetector.horizonYPerColumn(in: referenceMask)
        let tunedParams = tuneDetector(seedDetector, prepared: prepared, referenceY: referenceY)

        do {
            try tunedParams.save(toDirectory: paramsDir)
            Log.i("frame \(frameIndex) maybeTuneHorizonParameters: saved tuned parameters " +
                  "(MAE: \(tunedParams.tuningMeanAbsoluteError.map { String(format: "%.1f", $0) } ?? "n/a"))")
        } catch {
            Log.w("frame \(frameIndex) maybeTuneHorizonParameters: could not save parameters: \(error)")
        }
    }

    /// Coordinate-descent search over the four detector parameters.
    ///
    /// Two passes: each pass cycles through all parameters and picks the best
    /// value within the candidate range while keeping the others fixed.
    /// About 40 evaluations total — all using the pre-built `prepared` data so
    /// no disk I/O is required.
    private func tuneDetector(
        _ initial: HomographyHorizonDetector,
        prepared: HomographyHorizonDetector.PreparedData,
        referenceY: [Int?]
    ) -> HorizonTunedParameters {

        var best = initial
        var bestScore = Double.infinity
        if let mask = best.detectFromPrepared(prepared) {
            bestScore = HomographyHorizonDetector.score(
                algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                referenceY: referenceY
            )
        }

        let errorThresholdFactors: [Double] = [0.5, 1.0, 2.0, 3.0, 4.0]
        let errorSearchRanges:     [Int]    = [150, 250, 400, 550]
        let errorBlurRadii:        [Int]    = [2, 5, 8]
        let smoothingRadii:        [Int]    = [25, 50, 75, 100]

        for _ in 0..<2 {
            // Tune errorThresholdFactor
            for v in errorThresholdFactors {
                var candidate = best
                candidate.errorThresholdFactor = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune errorSearchRange
            for v in errorSearchRanges {
                var candidate = best
                candidate.errorSearchRange = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune errorBlurRadius
            for v in errorBlurRadii {
                var candidate = best
                candidate.errorBlurRadius = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune smoothingRadius
            for v in smoothingRadii {
                var candidate = best
                candidate.smoothingRadius = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
        }

        var params = HorizonTunedParameters()
        params.smoothingRadius      = best.smoothingRadius
        params.errorSearchRange     = best.errorSearchRange
        params.errorBlurRadius      = best.errorBlurRadius
        params.errorThresholdFactor = best.errorThresholdFactor
        params.errorSampleHalfWidth = best.errorSampleHalfWidth
        params.tuningMeanAbsoluteError = bestScore.isFinite ? bestScore : nil
        params.tuningFrameCount = 1
        return params
    }

    // MARK: - Live object-selection horizon preview

    /// Compute the snapped, interpolated per-column horizon Y for live preview
    /// in the horizon painter's "object selection" mode.
    ///
    /// **Algorithm** (adapted from GIMP's Foreground Select / SIOX):
    /// 1. Build a *sky centroid* in CIE L\*a\*b\* from the **bottom 20 %** of the
    ///    painted band (sky immediately adjacent to the ridgeline), and a *ground
    ///    centroid* from the bottom 5 % of the image (guaranteed terrain regardless
    ///    of how high up in the sky the user painted).
    /// 2. For each column scan **downward** from `bottomBoundaryY` computing the
    ///    SIOX ratio: `confidence = d_gnd / (d_sky + d_gnd)`.  The first row where
    ///    `confidence < 0.5` (closer to ground than sky) is the horizon.
    ///    The result is always at or below the painted bottom edge, so the
    ///    selection always expands *downward* toward terrain, never upward.
    ///
    /// Pixel colours are averaged over a ±20 px horizontal window (41 px total)
    /// before LAB conversion, suppressing stars (1–3 px wide) to ≤ 7 % of the
    /// window mean.  The scan additionally requires 3 consecutive terrain-like
    /// rows before declaring the horizon, eliminating false stops on the 1–2 px
    /// dark gaps between stars.
    ///
    /// - Parameters:
    ///   - topBoundaryY:    Per-column Y of the *top* edge of the painted area
    ///     (view coordinates, length = `viewWidth`).
    ///   - bottomBoundaryY: Per-column Y of the *bottom* edge of the painted area
    ///     (view coordinates, length = `viewWidth`).
    ///   - viewWidth:  Width of the frame view in points.
    ///   - viewHeight: Height of the frame view in points.
    /// - Returns: Per-column horizon Y in **view coordinates**
    ///   (length = `viewWidth`).  `nil` columns were not painted.
    /// SIOX three-region horizon detection.
    ///
    /// - Parameters:
    ///   - topBoundaryY: Per-column top of the horizon band (view coords).
    ///   - bottomBoundaryY: Per-column bottom of the horizon band (view coords).
    ///   - viewWidth: Width of the view.
    ///   - viewHeight: Height of the view.
    ///   - bandMode: Must be `true` for three-region SIOX.
    ///   - knownSkyFloorY: Per-column lowest Y known to be sky (view coords).
    ///     Defaults to `topBoundaryY` (initial band computation).
    ///   - knownGroundCeilingY: Per-column highest Y known to be ground (view coords).
    ///     Defaults to `bottomBoundaryY` (initial band computation).
    ///
    /// The algorithm classifies each pixel in the **unknown** region
    /// (between `knownSkyFloor` and `knownGroundCeiling`) by comparing its
    /// 4D feature vector (CIE L*a*b* colour + weighted linear luminance) to
    /// a single global sky centroid and a single global ground centroid,
    /// both computed from ALL known pixels.  The intensity channel provides
    /// Otsu-like brightness discrimination alongside perceptual colour.
    /// Known regions are never reclassified.
    public func computeLiveObjectSelection(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        bandMode: Bool = false,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        // 1. Load original image (async I/O — suspends without blocking).
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeLiveObjectSelection: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale the painted top + bottom boundaries: view coords → image pixel coords.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        // scaledTop[ix] / scaledBottom[ix]: image-pixel Y range painted in column ix.
        // Both are nil when the column was not painted at all.
        var scaledTop    = [Int?](repeating: nil, count: imgW)
        var scaledBottom = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), topBoundaryY.count - 1)
            if let topVY = topBoundaryY[col] {
                scaledTop[ix]    = Int((Double(topVY) * scaleY).rounded())
            }
            if let botVY = bottomBoundaryY[col] {
                scaledBottom[ix] = Int((Double(botVY) * scaleY).rounded())
            }
        }

        // Scale known-region boundaries: view coords → image pixel coords.
        // knownSkyFloor defaults to topBoundaryY (initial band computation).
        // knownGroundCeiling defaults to bottomBoundaryY.
        let skyFloorSrc   = knownSkyFloorY      ?? topBoundaryY
        let gndCeilingSrc = knownGroundCeilingY  ?? bottomBoundaryY
        var scaledSkyFloor   = [Int?](repeating: nil, count: imgW)
        var scaledGndCeiling = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), skyFloorSrc.count - 1)
            if let vy = skyFloorSrc[col] {
                scaledSkyFloor[ix] = Int((Double(vy) * scaleY).rounded())
            }
            if let vy = gndCeilingSrc[col] {
                scaledGndCeiling[ix] = Int((Double(vy) * scaleY).rounded())
            }
        }

        // 3. Horizon detection — SIOX-inspired LAB+intensity ratio
        //    (adapted from GIMP's Foreground Select tool; no Canny).
        //
        //    Stars make Canny unreliable: an isolated star produces the same
        //    high gradient as a mountain ridgeline.  Instead we use the SIOX
        //    "confidence" ratio from GIMP, applied per-column:
        //
        //        confidence = d_gnd / (d_sky + d_gnd)   (in CIE L*a*b* + I)
        //
        //    confidence > 0.5 → pixel closer to sky centroid   → still sky
        //    confidence < 0.5 → pixel closer to ground centroid → horizon found
        //
        //    The feature space is 4D: L*a*b* (perceptually uniform colour)
        //    plus linear luminance I (absolute brightness, Otsu-like).
        //    L* is a cube-root transform of luminance — perceptually uniform
        //    but compresses bright regions.  Adding linear luminance I as a
        //    4th channel preserves absolute brightness differences that help
        //    separate sky from terrain in difficult cases (similar-hue horizons,
        //    twilight scenes, very dark terrain against very dark sky).
        //
        //    Stars are suppressed by averaging pixels over a ±halfW horizontal
        //    window before converting to LAB+I.  A 3 px star in a 61 px window
        //    shifts the windowed mean by only ~5 %, not enough to flip the
        //    ratio.  The mountain silhouette causes a broad, sustained shift
        //    that reliably flips the ratio.
        //
        //    Implementation detail: prefix-sum trick gives O(imgW) per row
        //    instead of O(imgW × windowWidth) for the windowed cache.

        let halfW = 30   // horizontal window half-width (61 px total)
        // A 3 px star contributes only 3/61 ≈ 5 % of the window mean.
        // Even a 10 px star cluster = 16 %, insufficient to dominate a
        // region of continuous sky.  Mountain silhouettes are solid over
        // thousands of pixels and still dominate even with a 61 px window.

        // Weight for the linear-luminance intensity channel in the 4D
        // distance calculation.  Linear Y ranges [0,1]; L* ranges [0,100].
        // Multiplying Y by this weight puts it on a comparable scale to L*.
        // Higher values give more Otsu-like emphasis to raw brightness
        // differences; lower values rely more on perceptual colour.
        let intensityWeight: Float = 100.0

        let pixelData = Array(original.mat.buffer(of: UInt8.self))
        let pixStride = original.bytesPerRow
        let pxBpp     = max(1, original.bytesPerPixel)
        // OpenCV convention: channel order is [Blue=0, Green=1, Red=2, (Alpha=3)]

        let snapTop    = scaledTop
        let snapBottom = scaledBottom

        // Pre-compute the LAB band covering the full image height so we can
        // scan all the way down to terrain regardless of where the user painted.
        let globalTop = max(0, snapTop.compactMap { $0 }.min() ?? 0)
        let globalBot = imgH - 1   // always extend to the bottom of the image

        // `scaledY`: image-pixel horizon Y per image column (length = imgW).
        // Captures for Sendable closure.
        let skyFloor   = scaledSkyFloor
        let gndCeiling = scaledGndCeiling
        var scaledY: [Int?] = await Task.detached(priority: .userInitiated) {

            // ── Linearise LUT ─────────────────────────────────────────────────
            let linearLUT: [Float] = (0..<256).map { v in
                let n = Float(v) / 255.0
                return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
            }

            @inline(__always)
            func linRGBtoLABI(r: Float, g: Float, b: Float)
                -> (L: Float, a: Float, b: Float, I: Float)
            {
                let X = 0.4124564*r + 0.3575761*g + 0.1804375*b
                let Y = 0.2126729*r + 0.7151522*g + 0.0721750*b
                let Z = 0.0193339*r + 0.1191920*g + 0.9503041*b
                let Xn: Float = 0.95047, Yn: Float = 1.0, Zn: Float = 1.08883
                @inline(__always) func f(_ t: Float) -> Float {
                    t > 0.008856 ? pow(t, 1.0/3.0) : 7.787*t + (16.0/116.0)
                }
                let (fx, fy, fz) = (f(X/Xn), f(Y/Yn), f(Z/Zn))
                // L*a*b* for perceptual colour + linear luminance Y for
                // Otsu-like intensity discrimination.
                return (116.0*fy - 16.0,  500.0*(fx - fy),  200.0*(fy - fz),  Y)
            }

            // ── Phase A: build the windowed-LAB cache ──────────────────────────
            let rowStep = 2

            // Column range covering all painted columns.
            let colLeft  = snapTop.firstIndex(where: { $0 != nil }) ?? 0
            let colRight = snapTop.lastIndex(where:  { $0 != nil }) ?? (imgW - 1)
            guard colLeft <= colRight else { return [Int?](repeating: nil, count: imgW) }
            let colWidth = colRight - colLeft + 1

            let pxLeft  = max(0,        colLeft  - halfW)
            let pxRight = min(imgW - 1, colRight + halfW)
            let pxWidth = pxRight - pxLeft + 1

            let bandH = (globalBot - globalTop) / rowStep + 1
            var winL  = [Float](repeating: 0, count: bandH * colWidth)
            var winA  = [Float](repeating: 0, count: bandH * colWidth)
            var winBB = [Float](repeating: 0, count: bandH * colWidth)
            var winI  = [Float](repeating: 0, count: bandH * colWidth)

            for iy in stride(from: globalTop, through: globalBot, by: rowStep) {
                let ri = (iy - globalTop) / rowStep
                var prefR = [Float](repeating: 0, count: pxWidth + 1)
                var prefG = [Float](repeating: 0, count: pxWidth + 1)
                var prefB = [Float](repeating: 0, count: pxWidth + 1)
                for i in 0..<pxWidth {
                    let ix   = pxLeft + i
                    let base = iy * pixStride + ix * pxBpp
                    let bV   = linearLUT[Int(pixelData[base])]
                    let gV   = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV   = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    prefR[i+1] = prefR[i] + rV
                    prefG[i+1] = prefG[i] + gV
                    prefB[i+1] = prefB[i] + bV
                }
                for ix in colLeft...colRight {
                    let i   = ix - pxLeft
                    let lo  = max(0,          i - halfW)
                    let hi  = min(pxWidth - 1, i + halfW)
                    let cnt = Float(hi - lo + 1)
                    let mr  = (prefR[hi+1] - prefR[lo]) / cnt
                    let mg  = (prefG[hi+1] - prefG[lo]) / cnt
                    let mb  = (prefB[hi+1] - prefB[lo]) / cnt
                    let (L, a, lab_b, intensity) = linRGBtoLABI(r: mr, g: mg, b: mb)
                    let idx = ri * colWidth + (ix - colLeft)
                    winL[idx] = L;  winA[idx] = a;  winBB[idx] = lab_b
                    winI[idx] = intensity * intensityWeight
                }
            }

            // ── Phase B: SIOX three-region scan ───────────────────────────────

            @inline(__always)
            func labiAt(ix: Int, iy: Int) -> (L: Float, a: Float, b: Float, I: Float) {
                let ri  = min((iy - globalTop) / rowStep, bandH - 1)
                let idx = ri * colWidth + (ix - colLeft)
                return (winL[idx], winA[idx], winBB[idx], winI[idx])
            }
            @inline(__always)
            func dist2(_ l1: Float, _ a1: Float, _ b1: Float, _ i1: Float,
                       _ l2: Float, _ a2: Float, _ b2: Float, _ i2: Float) -> Float {
                let dL = l1-l2, da = a1-a2, db = b1-b2, di = i1-i2
                return dL*dL + da*da + db*db + di*di
            }

            let centroidColStep = max(1, (colRight - colLeft + 1) / 40)

            // ── Global sky centroid (4D: L*a*b* + intensity) ──────────────
            //
            // Computed from ALL known-sky pixels: everything from row 0 down
            // to knownSkyFloor[col] for each column.  This is a single global
            // centroid (no per-group segmentation) to avoid banding effects.
            var skyLSum: Float = 0, skyASum: Float = 0, skyBBSum: Float = 0
            var skyISum: Float = 0
            var nSky = 0
            for ix in stride(from: colLeft, through: colRight, by: centroidColStep) {
                let floor = skyFloor[ix] ?? snapTop[ix] ?? globalTop
                guard floor > 0 else { continue }
                let yStep = max(1, floor / 20)
                for iy in stride(from: 0, to: floor, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
                    let bV = linearLUT[Int(pixelData[base])]
                    let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    let (L, a, b, rawI) = linRGBtoLABI(r: rV, g: gV, b: bV)
                    skyLSum += L; skyASum += a; skyBBSum += b
                    skyISum += rawI * intensityWeight
                    nSky += 1
                }
            }
            let nSkyF = Float(max(1, nSky))
            let globalSkyL  = skyLSum  / nSkyF
            let globalSkyA  = skyASum  / nSkyF
            let globalSkyBB = skyBBSum / nSkyF
            let globalSkyI  = skyISum  / nSkyF

            // ── Global ground centroid (4D: L*a*b* + intensity) ──────────
            //
            // Computed from ALL known-ground pixels: everything from
            // knownGroundCeiling[col] down to imgH for each column.
            var gndLSum: Float = 0, gndASum: Float = 0, gndBBSum: Float = 0
            var gndISum: Float = 0
            var nGnd = 0
            for ix in stride(from: colLeft, through: colRight, by: centroidColStep) {
                let ceiling = gndCeiling[ix] ?? snapBottom[ix] ?? (imgH - 1)
                guard ceiling < imgH else { continue }
                let rowSpan = imgH - ceiling
                let yStep = max(1, rowSpan / 20)
                for iy in stride(from: ceiling, to: imgH, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
                    let bV = linearLUT[Int(pixelData[base])]
                    let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    let (L, a, b, rawI) = linRGBtoLABI(r: rV, g: gV, b: bV)
                    gndLSum += L; gndASum += a; gndBBSum += b
                    gndISum += rawI * intensityWeight
                    nGnd += 1
                }
            }
            let nGndF = Float(max(1, nGnd))
            let globalGndL  = gndLSum  / nGndF
            let globalGndA  = gndASum  / nGndF
            let globalGndBB = gndBBSum / nGndF
            let globalGndI  = gndISum  / nGndF

            // ── Per-column scan (unknown region only) ────────────────────────
            //
            // For each column, the scan region is the unknown gap:
            //   top  = knownSkyFloor[col]     (everything above is locked sky)
            //   bot  = knownGroundCeiling[col] (everything below is locked ground)
            //
            // We scan top-down through this gap.  The first run of
            // `minConsecutive` terrain-like rows marks the horizon.
            // If no terrain is found, the horizon defaults to the bottom
            // of the unknown gap (all unknown pixels are sky).

            let minConsecutive = 4
            var result = [Int?](repeating: nil, count: imgW)

            for ix in colLeft...colRight {
                guard let bandTop = snapTop[ix],
                      let bandBot = snapBottom[ix] else { continue }

                // Unknown region boundaries for this column.
                let unknownTop = max(0, skyFloor[ix]   ?? bandTop)
                let unknownBot = min(imgH - 1, gndCeiling[ix] ?? bandBot)

                guard unknownTop < unknownBot else {
                    // No unknown gap — horizon is at the sky floor.
                    result[ix] = unknownTop
                    continue
                }

                var consecutiveTerrain = 0
                var horizonY = unknownBot   // default: all unknown is sky
                for iy in unknownTop ..< unknownBot {
                    let (L, a, b, I) = labiAt(ix: ix, iy: iy)
                    if dist2(L, a, b, I, globalGndL, globalGndA, globalGndBB, globalGndI) <
                       dist2(L, a, b, I, globalSkyL, globalSkyA, globalSkyBB, globalSkyI) {
                        consecutiveTerrain += 1
                        if consecutiveTerrain >= minConsecutive {
                            horizonY = iy - minConsecutive + 1
                            break
                        }
                    } else {
                        consecutiveTerrain = 0
                    }
                }
                result[ix] = max(unknownTop, min(horizonY, unknownBot))
            }
            return result
        }.value

        // 4. Linear-interpolate gaps between painted image columns.
        var lastValidIdx: Int? = nil
        var lastValidY:   Int  = 0
        for ix in 0..<imgW {
            if let y = scaledY[ix] {
                if let prev = lastValidIdx, prev < ix - 1 {
                    let span = ix - prev
                    for gap in (prev + 1)..<ix {
                        let t = Double(gap - prev) / Double(span)
                        scaledY[gap] = Int((Double(lastValidY) * (1 - t) + Double(y) * t).rounded())
                    }
                }
                lastValidIdx = ix
                lastValidY   = y
            }
        }

        // 4b. Median filter — removes isolated per-column spikes caused by snow
        //     patches, bright terrain features, or stray dark/bright pixels that
        //     shift the SIOX ratio for only a few individual columns.
        //     A ±medW window replaces each column's value with the median of its
        //     neighbours, eliminating narrow outliers while preserving the broad
        //     horizon curve.
        let medW = 40
        var smoothedY = scaledY
        for ix in 0..<imgW {
            guard scaledY[ix] != nil else { continue }
            let lo = max(0, ix - medW)
            let hi = min(imgW - 1, ix + medW)
            var window: [Int] = []
            window.reserveCapacity(hi - lo + 1)
            for jx in lo...hi { if let y = scaledY[jx] { window.append(y) } }
            if !window.isEmpty {
                window.sort()
                smoothedY[ix] = window[window.count / 2]
            }
        }
        scaledY = smoothedY

        // 5. Convert image-pixel coords → view coords.
        //    `applyExpandedHorizonMask` renders into a Canvas sized at view dimensions,
        //    so the returned array MUST have `viewWidth` elements with view-coord Ys.
        var viewY = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            if let iy = scaledY[ix] {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }

        return viewY
    }

    // MARK: - Random Walker horizon detection

    // MARK: - CombinedHorizonDetector interactive detection

    /// Fill nil values at the leading and trailing edges of an array with
    /// nearest-neighbour extrapolation.  Interior nil runs are left unchanged.
    private static func fillEdgeNils(_ arr: [Int?]) -> [Int?] {
        var result = arr
        if let first = result.first(where: { $0 != nil }) {
            for i in result.indices { if result[i] != nil { break }; result[i] = first }
        }
        if let last = result.last(where: { $0 != nil }) {
            for i in result.indices.reversed() { if result[i] != nil { break }; result[i] = last }
        }
        return result
    }

    /// Horizon detection within the user's painted band using `CombinedHorizonDetector`.
    ///
    /// Runs the full multi-method pipeline (Otsu, DP, SIOX, gradient, texture)
    /// constrained to the painted band region.  Locked sky/ground regions —
    /// set by user brush strokes during refinement — are honoured in the output
    /// and are never re-classified by the detector.  Edge columns that were not
    /// painted are filled by nearest-neighbour extrapolation so the horizon
    /// always covers the full frame width.
    ///
    /// - Parameters:
    ///   - topBoundaryY:         Per-column top of painted band (view coords).
    ///   - bottomBoundaryY:      Per-column bottom of painted band (view coords).
    ///   - viewWidth:            Width of the view in points.
    ///   - viewHeight:           Height of the view in points.
    ///   - knownSkyFloorY:       Per-column lowest Y confirmed as sky (view coords).
    ///   - knownGroundCeilingY:  Per-column highest Y confirmed as ground (view coords).
    /// - Returns: Per-column horizon Y in view coordinates, edge-extrapolated.
    public func computeCombinedHorizonInBand(
        topBoundaryY: [Int?],
        bottomBoundaryY: [Int?],
        viewWidth: Int,
        viewHeight: Int,
        knownSkyFloorY: [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeCombinedHorizonInBand: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        // Edge-fill the band boundaries so all columns have a value.
        let topFilled = FrameAirplaneRemover.fillEdgeNils(topBoundaryY)
        let botFilled = FrameAirplaneRemover.fillEdgeNils(bottomBoundaryY)

        // Per-column effective detection window:
        // top = max(knownSkyFloor, bandTop)   — narrowed by user painting sky downward
        // bot = min(knownGroundCeiling, bandBot) — narrowed by user erasing upward
        let skyFloorSrc = FrameAirplaneRemover.fillEdgeNils(
            knownSkyFloorY ?? topFilled
        )
        let gndCeilSrc = FrameAirplaneRemover.fillEdgeNils(
            knownGroundCeilingY ?? botFilled
        )

        var effectiveTop = [Int?](repeating: nil, count: viewWidth)
        var effectiveBot = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let sf = skyFloorSrc[vx]
            let tb = topFilled[vx]
            effectiveTop[vx] = (sf != nil && tb != nil) ? max(sf!, tb!) : (sf ?? tb)

            let gc = gndCeilSrc[vx]
            let bb = botFilled[vx]
            effectiveBot[vx] = (gc != nil && bb != nil) ? min(gc!, bb!) : (gc ?? bb)
        }

        // Set SIOX band fractions from the global effective window.
        let globalTopView  = effectiveTop.compactMap { $0 }.min() ?? 0
        let globalBotView  = effectiveBot.compactMap { $0 }.max() ?? viewHeight
        var params = CombinedHorizonDetector.Params()
        params.sioxBandTopFraction    = max(0.0, Double(globalTopView)  / Double(viewHeight) - 0.02)
        params.sioxBandBottomFraction = min(1.0, Double(globalBotView)  / Double(viewHeight) + 0.02)

        // Run the full combined detection pipeline.
        let horizonMask = try await CombinedHorizonDetector.detect(image: original, params: params)

        // Extract per-column Y (image-pixel coords) from the binary mask.
        let detectedImgY = CombinedHorizonDetector.extractHorizonY(from: horizonMask.image)

        // Map to view coords and clamp each column to its effective window.
        var result = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            guard var iy = detectedImgY[ix] else { continue }

            // Clamp to per-column effective window (image-pixel coords).
            if let topVY = effectiveTop[vx] {
                iy = max(iy, Int((Double(topVY) * scaleY).rounded()))
            }
            if let botVY = effectiveBot[vx] {
                iy = min(iy, Int((Double(botVY) * scaleY).rounded()))
            }

            result[vx] = Int((Double(iy) / scaleY).rounded())
        }

        // Edge-extrapolate so the horizon spans the full frame width.
        return FrameAirplaneRemover.fillEdgeNils(result)
    }

    /// Edge-aware Random Walker horizon detection within the user's painted band.
    ///
    /// This is an alternative to the SIOX method in `computeLiveObjectSelection`.
    /// It solves a graph-based diffusion problem where:
    /// - Above the band = sky seeds (probability 1.0)
    /// - Below the band = ground seeds (probability 0.0)
    /// - Within the band = unknown, solved via Gauss-Seidel iteration
    /// - Edge weights = exp(-beta * gradient^2): strong edges resist crossing
    ///
    /// The horizon is found by scanning **upward** from the ground seeds,
    /// locating where the sky probability crosses 0.5.  Results are edge-snapped
    /// to the nearest strong vertical gradient and median-filtered.
    ///
    /// The algorithm operates on a downsampled copy (max 2048px wide) for
    /// performance, with multi-scale solving for fast convergence.
    /// Stars are suppressed via Gaussian pre-blur.
    ///
    /// - Parameters:
    ///   - topBoundaryY:         Per-column top of painted band (view coords).
    ///   - bottomBoundaryY:      Per-column bottom of painted band (view coords).
    ///   - viewWidth:            Width of the view.
    ///   - viewHeight:           Height of the view.
    ///   - knownSkyFloorY:       Per-column lowest Y known sky (view coords).
    ///   - knownGroundCeilingY:  Per-column highest Y known ground (view coords).
    ///   - beta:                 Edge weight sensitivity (default 90).
    /// - Returns: Per-column horizon Y in view coordinates. `nil` = unpainted.
    public func computeRandomWalkerHorizon(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil,
        beta: Double = 90.0
    ) async throws -> [Int?] {
        // 1. Load original image.
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeRandomWalkerHorizon: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale view coords → image pixel coords.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        let skyFloorSrc   = knownSkyFloorY     ?? topBoundaryY
        let gndCeilingSrc = knownGroundCeilingY ?? bottomBoundaryY

        // Build Int32 arrays for C bridge.  -1 = unpainted column.
        var bandTop    = [Int32](repeating: -1, count: imgW)
        var bandBottom = [Int32](repeating: -1, count: imgW)
        var skyFloor   = [Int32](repeating: -1, count: imgW)
        var gndCeiling = [Int32](repeating: -1, count: imgW)

        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), topBoundaryY.count - 1)

            if let topVY = topBoundaryY[col] {
                bandTop[ix] = Int32(min(max(Int((Double(topVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let botVY = bottomBoundaryY[col] {
                bandBottom[ix] = Int32(min(max(Int((Double(botVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let skyVY = skyFloorSrc[col] {
                skyFloor[ix] = Int32(min(max(Int((Double(skyVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let gndVY = gndCeilingSrc[col] {
                gndCeiling[ix] = Int32(min(max(Int((Double(gndVY) * scaleY).rounded()), 0), imgH - 1))
            }
        }

        // 3. Call Random Walker C++ implementation.
        let horizonY = PixelatedImageBridge.randomWalkerHorizon(
            original.mat,
            bandTopY: bandTop,
            bandBottomY: bandBottom,
            skyFloorY: skyFloor,
            groundCeilY: gndCeiling,
            beta: beta
        )

        // 4. Convert image pixel coords → view coords.
        var viewY = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            let iy = horizonY[ix]
            if iy >= 0 {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }

        return viewY
    }

    // MARK: - Load existing reference horizon for interactive editing

    /// Return the existing user-painted reference horizon as per-column Y values
    /// in **view** coordinates, or `nil` if no reference mask exists on disk.
    ///
    /// Used by `HorizonPainterView` to pre-populate the painter when the user
    /// opens the tool on a frame that already has a saved reference, so they
    /// can jump straight into refinement rather than re-painting the band.
    public func loadExistingHorizonReferenceAsViewY(
        viewWidth:  Int,
        viewHeight: Int
    ) async throws -> [Int?]? {
        guard let mask = try await loadHorizonReferenceMask() else { return nil }
        return horizonMaskToViewY(mask, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Loads the best available existing horizon for this frame into view
    /// coordinates, without computing or creating anything.
    ///
    /// Search order (highest quality first):
    /// 1. User-painted reference in `horizonReference/`
    /// 2. Cached `refinedHorizon` from a previous pipeline run
    /// 3. Cached `mergedHorizon`
    /// 4. Raw `horizon`
    ///
    /// Returns `nil` if no horizon data exists for this frame.
    public func loadBestExistingHorizonAsViewY(
        viewWidth:  Int,
        viewHeight: Int
    ) async throws -> [Int?]? {
        if let result = try await loadExistingHorizonReferenceAsViewY(
               viewWidth: viewWidth, viewHeight: viewHeight) {
            return result
        }
        for type in [FrameViewMode.refinedHorizon, .mergedHorizon, .horizon] {
            if let image = try? await imageAccessor.load(
                   frameIndex: frameIndex, type: type, atSize: .original),
               let horizonMask = image.asHorizonMask,
               let mask = HorizonMask(horizonMask)
            {
                return horizonMaskToViewY(mask,
                                          viewWidth:  viewWidth,
                                          viewHeight: viewHeight)
            }
        }
        return nil
    }

    private func horizonMaskToViewY(
        _ mask: HorizonMask,
        viewWidth:  Int,
        viewHeight: Int
    ) -> [Int?] {
        let imgW   = mask.image.width
        let imgH   = mask.image.height
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)
        let imgY   = CombinedHorizonDetector.extractHorizonY(from: mask.image)
        var viewY  = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            if let iy = imgY[ix] {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }
        return FrameAirplaneRemover.fillEdgeNils(viewY)
    }

    // MARK: - Filmstrip horizon thumbnail overlay

    /// Returns `true` if a user-painted reference horizon file exists on disk
    /// for this frame (either per-frame or global).  Synchronous — no I/O beyond
    /// a file-existence check.
    public var hasHorizonReference: Bool {
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else { return false }
        let refinedURL    = URL(fileURLWithPath: refinedPath)
        let frameFileName = refinedURL.lastPathComponent
        let referenceDir  = refinedURL
            .deletingLastPathComponent()    // …/refinedHorizon
            .deletingLastPathComponent()    // …/output
            .appendingPathComponent("horizonReference")
        return FileManager.default.fileExists(
                   atPath: referenceDir.appendingPathComponent(frameFileName).path)
            || FileManager.default.fileExists(
                   atPath: referenceDir.appendingPathComponent("reference.tiff").path)
    }

    /// Load the best-available horizon for this frame and scale it to thumbnail
    /// dimensions, returning a `HorizonThumbnailOverlay` suitable for drawing
    /// directly on a filmstrip cell.
    ///
    /// Priority: **reference** (green) › **merged** (blue) › **initial** (white).
    /// Returns `nil` when no horizon of any kind has been computed yet.
    ///
    /// - Parameters:
    ///   - thumbnailWidth:  Width of the thumbnail in pixels.
    ///   - thumbnailHeight: Height of the thumbnail in pixels.
    public func loadHorizonThumbnailOverlay(
        thumbnailWidth:  Int,
        thumbnailHeight: Int
    ) async throws -> HorizonThumbnailOverlay? {

        // ── Choose the best available source ────────────────────────────────
        let pixImage: PixelatedImage
        let kind: HorizonThumbnailOverlay.Kind

        if let refMask = try await loadHorizonReferenceMask() {
            pixImage = refMask.image
            kind     = .reference
        } else if let mergedImage = try await imageAccessor.load(
                      frameIndex: frameIndex,
                      type: .mergedHorizon,
                      atSize: .original)
        {
            pixImage = mergedImage
            kind     = .merged
        } else if let initialImage = try await imageAccessor.load(
                      frameIndex: frameIndex,
                      type: .horizon,
                      atSize: .original)
        {
            pixImage = initialImage
            kind     = .initial
        } else {
            return nil
        }

        // ── Scale image-space horizon Y → thumbnail Y ────────────────────
        let imgW   = pixImage.width
        let imgH   = pixImage.height
        let scaleX = Double(imgW) / Double(thumbnailWidth)
        let scaleY = Double(imgH) / Double(thumbnailHeight)

        let imgY   = CombinedHorizonDetector.extractHorizonY(from: pixImage)

        var thumbY = [Int](repeating: thumbnailHeight / 2, count: thumbnailWidth)
        for tx in 0..<thumbnailWidth {
            let ix = min(max(0, Int((Double(tx) * scaleX).rounded())), imgW - 1)
            if let iy = imgY[ix] {
                thumbY[tx] = min(thumbnailHeight - 1,
                                 max(0, Int((Double(iy) / scaleY).rounded())))
            }
        }

        return HorizonThumbnailOverlay(kind: kind, yPerColumn: thumbY)
    }

    // MARK: - Save user-painted reference horizon mask

    /// Convert a painted horizon (from `HorizonPainterView`) into a binary
    /// `HorizonMask` TIFF and write it to the `horizonReference/` directory.
    ///
    /// - Parameters:
    ///   - paintedYPerColumn: Per-column painted horizon Y in *view* coordinates.
    ///   - viewWidth:  Width of the frame view in points (view coordinate space).
    ///   - viewHeight: Height of the frame view in points.
    public func saveHorizonReferenceMask(
        paintedYPerColumn: [Int?],
        viewWidth:  Int,
        viewHeight: Int
    ) async throws {
        // 1. Load original image to get actual pixel dimensions.
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "saveHorizonReferenceMask: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale painted Y from view coordinates → image pixel coordinates.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        var scaledY = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            // Map image column back to nearest painted column.
            let vx = Int((Double(ix) / scaleX).rounded())
            let paintedCol = min(max(vx, 0), paintedYPerColumn.count - 1)
            if let vy = paintedYPerColumn[paintedCol] {
                scaledY[ix] = Int((Double(vy) * scaleY).rounded())
            }
        }

        // 3. Linear-interpolate gaps between painted columns.
        var lastValidIdx: Int? = nil
        var lastValidY:   Int  = 0
        for ix in 0..<imgW {
            if let y = scaledY[ix] {
                if let prev = lastValidIdx, prev < ix - 1 {
                    let span = ix - prev
                    for gap in (prev + 1)..<ix {
                        let t = Double(gap - prev) / Double(span)
                        scaledY[gap] = Int((Double(lastValidY) * (1 - t) + Double(y) * t).rounded())
                    }
                }
                lastValidIdx = ix
                lastValidY   = y
            }
        }

        // 4. Build the binary mask image.
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width:  Int32(imgW),
            height: Int32(imgH),
            horizonY: scaledY
        )
        guard let maskPixelated = PixelatedImage(mat: maskMat) else {
            throw "saveHorizonReferenceMask: could not create mask image for frame \(frameIndex)"
        }

        // 5. Determine save path inside horizonReference/.
        guard let refinedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .refinedHorizon,
                atSize: .original
              )
        else {
            throw "saveHorizonReferenceMask: cannot determine output path for frame \(frameIndex)"
        }
        let refinedURL    = URL(fileURLWithPath: refinedPath)
        let frameFileName = refinedURL.lastPathComponent
        let referenceDir  = refinedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("horizonReference")

        try FileManager.default.createDirectory(
            at: referenceDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let config = await configManager.config()
        let saveName = config.tripodHeadWasMoving ? frameFileName : "reference.tiff"
        let savePath = referenceDir.appendingPathComponent(saveName).path

        maskPixelated.writeTIFFEncoding(toFilename: savePath)
        Log.i("frame \(frameIndex) saveHorizonReferenceMask: saved \(savePath)")
    }

    // this horizon mask is calculated based upon this frame only.
    // Uses adaptive parameter search: runs horizon detection at reduced resolution
    // with multiple parameter combinations, scores each result, then applies the
    // best parameters at full resolution.
    internal func loadOrCreateHorizonMask() async throws -> HorizonMask {
        // If the user has painted a reference horizon, use it directly.
        if let referenceMask = try await loadHorizonReferenceMask() {
            Log.i("frame \(frameIndex) loadOrCreateHorizonMask: using reference mask (skipping base detection)")
            return referenceMask
        }
        Log.d("frame \(frameIndex) trying to load horizon mask")
        // load if possible
        do {
            if let horizonMaskImage = try await imageAccessor.load(
                 frameIndex: frameIndex,
                 type: .horizon,
                 atSize: .original
               )
            {
                Log.d("frame \(frameIndex) successfully loaded horizon mask")
                if let mask = HorizonMask(horizonMaskImage) {
                    return mask
                }
                Log.w("frame \(frameIndex) loaded horizon mask image but could not compute bounds")
            }
        } catch {
            Log.i("frame \(frameIndex) unable to load horizon mask: \(error)")
        }
        Log.d("frame \(frameIndex) trying to create horizon mask")

        self.set(state: .horizonDetection)
        let config = await configManager.config()
        let adaptiveState = configManager.adaptiveHorizonState

        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "cannot load original image for horizon detection"
        }

        let horizonMask: HorizonMask

        if config.useCombinedHorizonDetection {
            // Combined+RW pipeline: run Otsu, DP, SIOX in parallel, median-combine,
            // then refine with Random Walker. Best-performing method as of 2026-03.
            Log.i("frame \(frameIndex) using combined+RW horizon detection")
            horizonMask = try await CombinedHorizonDetector.detect(image: original)
        } else {
            // Legacy adaptive search: Otsu multi-crop + DP grid search
            let useAdaptiveSearch = config.horizonSearchCropBounds.count >= 2

            if useAdaptiveSearch {
                horizonMask = try await adaptiveHorizonSearch(
                  original: original,
                  config: config,
                  adaptiveState: adaptiveState
                )
            } else {
                // Fallback: single parameter set, same as original behavior
                let bottomPercentage: Double = 50
                guard let mask = try await original.horizonMask(
                        at: frameIndex,
                        bottomPercentage: bottomPercentage,
                        useCannyEdgeDetection: config.useCannyForHorizonDetection,
                        cannyMinThreshold: config.cannyMinThreshold,
                        cannyMaxThreshold: config.cannyMaxThreshold,
                        useL2Gradient: config.cannyUseL2Gradient
                      )
                else {
                    throw "cannot create horizon mask"
                }
                horizonMask = mask
            }
        }

        Log.d("frame \(frameIndex) horizon mask image \(horizonMask.image) created")
        try await imageAccessor.save(
          horizonMask.image,
          frameIndex: frameIndex,
          as: .horizon,
          atSizes: await self.outputSizes,
          overwrite: true
        )

        self.set(state: .horizonDetected)
        return horizonMask
    }

    /// Run horizon detection at reduced resolution with a two-pass parameter search,
    /// score each result, then apply the best parameters at full resolution.
    ///
    /// Pass 1: Coarse search across the full crop bounds range with horizonSearchCropCount1
    ///         steps, testing all strip width combinations.
    /// Pass 2: Refined search centered on the pass-1 best crop value, spanning one
    ///         pass-1 step in each direction, divided into horizonSearchCropCount2 steps.
    ///         Only the best strip width from pass 1 is used.
    private func adaptiveHorizonSearch(
      original: PixelatedImage,
      config: Config,
      adaptiveState: AdaptiveHorizonState
    ) async throws -> HorizonMask {
        let shrunkWidth = UInt(config.horizonSearchSize[0])
        let shrunkHeight = UInt(config.horizonSearchSize[1])

        // Step 1: Create reduced-resolution image for parameter search
        guard let shrunkImage = original.downScaleTo(
                width: shrunkWidth,
                height: shrunkHeight
              )
        else {
            Log.w("frame \(frameIndex) unable to downscale for adaptive horizon search, falling back")
            throw "cannot downscale image for adaptive horizon search"
        }

        // Pre-compute Canny edges on the shrunk image once for scoring all candidates.
        let shrunkEdgeImage: PixelatedImage? = try? shrunkImage.cannyEdgeDetect(
          minThreshold: config.cannyMinThreshold,
          maxThreshold: config.cannyMaxThreshold,
          useL2Gradient: config.cannyUseL2Gradient
        )

        // Step 2: Determine first-pass parameter search space.
        // After the first frame, narrow the bounds based on what worked before.
        let cropBounds: [Double] = await adaptiveState.narrowedCropBounds(
          defaults: config.horizonSearchCropBounds,
          narrowingRange: config.horizonSearchNarrowingRange
        )
        let pass1CropAmounts = HorizonCropAmounts.firstPass(
          bounds: cropBounds,
          count: config.horizonSearchCropCount1
        )
        let pass1Step = HorizonCropAmounts.firstPassStep(
          bounds: cropBounds,
          count: config.horizonSearchCropCount1
        )

        Log.i("frame \(frameIndex) adaptive horizon pass 1: " +
              "cropAmounts=\(pass1CropAmounts), ")

        // Step 3: Run first-pass combinations in parallel at reduced resolution
        let pass1Results = try await runScoredHorizonSearch(
          cropAmounts: pass1CropAmounts,
          shrunkImage: shrunkImage,
          shrunkEdgeImage: shrunkEdgeImage,
          shrunkWidth: shrunkWidth,
          config: config
        )

        // Tie-break on equal total score: prefer larger cropAmount (more conservative
        // sky crop). A larger crop is less likely to bite into the real horizon; when
        // the algorithm can't distinguish candidates by score it should stay safe.
        guard let pass1Best = pass1Results.max(by: {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore < $1.score.totalScore
            }
            return $0.cropAmount < $1.cropAmount   // higher cropAmount wins
        })
        else {
            throw "adaptive horizon search pass 1 produced no valid results"
        }

        Log.i("frame \(frameIndex) pass 1 best: " +
              "cropAmount=\(pass1Best.cropAmount), " +
              "score=\(pass1Best.score)")

        for result in pass1Results.sorted(by: { $0.score.totalScore > $1.score.totalScore }) {
            Log.d("frame \(frameIndex) pass 1 result: " +
                  "crop=\(result.cropAmount)" +
                  "score=\(result.score)")
        }

        // Step 4: Second pass - refine the crop amount around the pass-1 best.
        // The search area spans one pass-1 step in each direction, divided into
        // horizonSearchCropCount2 evenly spaced values.
        // Strip width is fixed to the pass-1 best.
        let pass2CropAmounts = HorizonCropAmounts.secondPass(
          bestCrop: pass1Best.cropAmount,
          firstPassStep: pass1Step,
          count: config.horizonSearchCropCount2
        )

        Log.i("frame \(frameIndex) adaptive horizon pass 2: " +
              "cropAmounts=\(pass2CropAmounts)")

        let pass2Results = try await runScoredHorizonSearch(
          cropAmounts: pass2CropAmounts,
          shrunkImage: shrunkImage,
          shrunkEdgeImage: shrunkEdgeImage,
          shrunkWidth: shrunkWidth,
          config: config
        )

        // Same tie-break as pass 1: prefer larger cropAmount on equal scores.
        guard let pass2Best = pass2Results.max(by: {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore < $1.score.totalScore
            }
            return $0.cropAmount < $1.cropAmount   // higher cropAmount wins
        })
        else {
            throw "adaptive horizon search pass 2 produced no valid results"
        }

        Log.i("frame \(frameIndex) pass 2 best: " +
              "cropAmount=\(pass2Best.cropAmount), " +
              "score=\(pass2Best.score)")

        for result in pass2Results.sorted(by: { $0.score.totalScore > $1.score.totalScore }) {
            Log.d("frame \(frameIndex) pass 2 result: " +
                  "crop=\(result.cropAmount)," +
                  "score=\(result.score)")
        }

        // Step 5: DP grid search on the shrunk image (if enabled).
        // Run DP across all combinations of smoothnessLambda, sobelWeight, cannyWeight
        // defined by the range+count config parameters. Each candidate is scored on the
        // shrunk image using the same pre-computed Canny edge image used for Otsu scoring,
        // so all candidates (Otsu and DP) are comparable on equal footing.
        //
        var dpBestShrunkResult: HorizonSearchResult? = nil


        let dpSearchTop    = pass2Best.cropAmount/100
        let dpSearchBottom = 1.0

        let lambdaValues = config.dpHorizonSmoothnessLambdaValues
        let sobelValues  = config.dpHorizonSobelWeightValues
        let cannyValues  = config.dpHorizonCannyWeightValues
        let dpTotal      = lambdaValues.count * sobelValues.count * cannyValues.count

        Log.i("frame \(frameIndex) DP shrunk-image grid: " +
                "\(dpTotal) combinations " +
                "(lambda×\(lambdaValues.count), sobel×\(sobelValues.count), canny×\(cannyValues.count)), " +
                "search \(String(format:"%.0f",dpSearchTop*100))%–" +
                "\(String(format:"%.0f",dpSearchBottom*100))% of image height")

        // Run all DP combinations in parallel on the shrunk image.
        struct DPShrunkResult {
            let mask: HorizonMask
            let lambda: Double
            let sobelW: Double
            let cannyW: Double
        }

        let dpShrunkResults: [DPShrunkResult] = try await withThrowingTaskGroup(
          of: DPShrunkResult?.self
        ) { taskGroup in
            for lambda in lambdaValues {
                for sobelW in sobelValues {
                    for cannyW in cannyValues {
                        taskGroup.addTask { [frameIndex] in
                            guard let mask = try? await shrunkImage.dpHorizonMask(
                                    at: frameIndex,
                                    searchTopFraction: dpSearchTop,
                                    searchBottomFraction: dpSearchBottom,
                                    cannyMinThreshold: config.cannyMinThreshold,
                                    cannyMaxThreshold: config.cannyMaxThreshold,
                                    useL2Gradient: config.cannyUseL2Gradient,
                                    smoothnessLambda: lambda,
                                    sobelWeight: sobelW,
                                    cannyWeight: cannyW
                                  )
                            else { return nil }
                            return DPShrunkResult(mask: mask, lambda: lambda,
                                                  sobelW: sobelW, cannyW: cannyW)
                        }
                    }
                }
            }
            var results: [DPShrunkResult] = []
            for try await result in taskGroup {
                if let r = result { results.append(r) }
            }
            return results
        }

        // Score each DP shrunk result and find the best.
        for dpResult in dpShrunkResults {
            let score: HorizonScore
            if let edges = shrunkEdgeImage {
                score = HorizonScoring.score(horizonMask: dpResult.mask, edgeImage: edges)
            } else {
                score = HorizonScoring.score(
                  horizonMask: dpResult.mask,
                  originalImage: shrunkImage,
                  cannyMinThreshold: config.cannyMinThreshold,
                  cannyMaxThreshold: config.cannyMaxThreshold,
                  useL2Gradient: config.cannyUseL2Gradient
                )
            }
            Log.d("frame \(frameIndex) DP shrunk score=\(score) " +
                    "lambda=\(dpResult.lambda) sobel=\(dpResult.sobelW) canny=\(dpResult.cannyW)")

            // Store as a HorizonSearchResult using cropAmount=-1 as a sentinel
            // (DP doesn't have a crop amount; the sentinel is only used for logging).
            let candidate = HorizonSearchResult(
              cropAmount: -1, 
              horizonMask: dpResult.mask, score: score,
              lambda: dpResult.lambda, sobelW: dpResult.sobelW, cannyW: dpResult.cannyW
            )
            if let current = dpBestShrunkResult {
                if score.totalScore > current.score.totalScore {
                    dpBestShrunkResult = candidate
                }
            } else {
                dpBestShrunkResult = candidate
            }
        }

        if let best = dpBestShrunkResult {
            Log.i("frame \(frameIndex) DP shrunk best score=\(best.score) " +
                    "lambda=\(best.lambda ?? -1) sobel=\(best.sobelW ?? -1) " +
                    "canny=\(best.cannyW ?? -1)")
        } else {
            Log.w("frame \(frameIndex) DP shrunk grid produced no valid results")
        }


        // Step 6: Run BOTH Otsu and DP at full and shrunk resolutions,
        // then combine and score all of them.
        //
        // We always generate:
        //   (a) otsuMask   — Otsu + Canny at full res with pass-2 best parameters
        //   (b) shrunkOtsu — Otsu + Canny at smaller res with pass-2 best parameters
        //   (c) dpMask     — DP at full res with shrunk-grid-best parameters (if enabled)
        //   (d) shrunkDp   — DP at shrunk res with shrunk-grid-best parameters (if enabled)
        //
        // Each of the four is scored independently; the highest-scoring one is returned.
        // When DP is disabled only (a) is produced.

        // --- 6d: DP at smaller resolution ---
        if let dpBest = dpBestShrunkResult,
           let lambda = dpBest.lambda,
           let sobelW = dpBest.sobelW,
           let cannyW = dpBest.cannyW
        {
            let dpSearchTop    = pass2Best.cropAmount / 100.0
            let dpSearchBottom = 1.0

            Log.i("frame \(frameIndex) running DP at smaller resolution: " +
                  "lambda=\(lambda), sobel=\(sobelW), canny=\(cannyW), " +
                  "search \(String(format:"%.0f",dpSearchTop*100))%–" +
                  "\(String(format:"%.0f",dpSearchBottom*100))%")

            if let ogdpShrunkMask = try? await shrunkImage.dpHorizonMask(
                 at: frameIndex,
                 searchTopFraction: dpSearchTop,
                 searchBottomFraction: dpSearchBottom,
                 cannyMinThreshold: config.cannyMinThreshold,
                 cannyMaxThreshold: config.cannyMaxThreshold,
                 useL2Gradient: config.cannyUseL2Gradient,
                 smoothnessLambda: lambda,
                 sobelWeight: sobelW,
                 cannyWeight: cannyW
               )
            {
                // re-scale it back up
                let dpFullResMask = HorizonMask(
                  image: ogdpShrunkMask.image
                    .upScaleTo(
                      width: UInt(original.width),
                      height: UInt(original.height)
                    )!,
                  horizonTopY: ogdpShrunkMask.horizonTopY,
                  horizonBottomY: ogdpShrunkMask.horizonBottomY
                )
                let dpFullResScore: HorizonScore
/*
                if let edges = shrunkEdgeImage {
                    dpFullResScore = HorizonScoring.score(
                      horizonMask: dpFullResMask,
                      edgeImage: edges
                    )
                } else {*/
                    dpFullResScore = HorizonScoring.score(
                      horizonMask: dpFullResMask,
                      originalImage: original,
                      cannyMinThreshold: config.cannyMinThreshold,
                      cannyMaxThreshold: config.cannyMaxThreshold,
                      useL2Gradient: config.cannyUseL2Gradient
                    )
//                }
                Log.i("frame \(frameIndex) DP full resolution score=\(dpFullResScore)")


                let bestMask   = dpFullResMask
                let bestScore  = dpFullResScore
                let bestMethod = "shrunkDp"


                Log.i("frame \(frameIndex) final horizon method=\(bestMethod), score=\(bestScore)")

                // Step 7: Record the best parameters for narrowing subsequent frames
                await adaptiveState.recordBest(
                  cropAmount: pass2Best.cropAmount,
                  firstPassStep: pass1Step
                )

                return bestMask
                
            }
        }

        // --- 6b: Otsu at shrunk resolution

        guard let ogShrunkOtsuMask = try await shrunkImage.horizonMask(
                at: frameIndex,
                bottomPercentage: pass2Best.cropAmount,
                useCannyEdgeDetection: config.useCannyForHorizonDetection,
                cannyMinThreshold: config.cannyMinThreshold,
                cannyMaxThreshold: config.cannyMaxThreshold,
                useL2Gradient: config.cannyUseL2Gradient
              )
        else {
            throw "cannot create full resolution Otsu horizon mask"
        }

        // re-scale it back up
        let shrunkOtsuMask = HorizonMask(
          image: ogShrunkOtsuMask.image
            .upScaleTo(
              width: UInt(original.width),
              height: UInt(original.height)
            )!,
          horizonTopY: ogShrunkOtsuMask.horizonTopY,
          horizonBottomY: ogShrunkOtsuMask.horizonBottomY
        )
        
        let shrunkResCropBoundaryY = Int(Double(shrunkImage.height) * pass2Best.cropAmount / 100)
        /*
         if let edges = shrunkEdgeImage {
         shrunkOtsuScore = HorizonScoring.score(
         horizonMask: shrunkOtsuMask,
         edgeImage: edges,
         cropBoundaryY: shrunkResCropBoundaryY
         )
         } else {*/

        let shrunkOtsuScore = HorizonScoring.score(
          horizonMask: shrunkOtsuMask,
          originalImage: shrunkImage,
          cannyMinThreshold: config.cannyMinThreshold,
          cannyMaxThreshold: config.cannyMaxThreshold,
          useL2Gradient: config.cannyUseL2Gradient,
          cropBoundaryY: shrunkResCropBoundaryY
        )
        //        }
        Log.i("frame \(frameIndex) Otsu full resolution score=\(shrunkOtsuScore)")

        // Step 7: Record the best parameters for narrowing subsequent frames
        await adaptiveState.recordBest(
          cropAmount: pass2Best.cropAmount,
          firstPassStep: pass1Step
        )

        return shrunkOtsuMask
        
    }

    /// Run horizon detection and scoring for all combinations of crop amounts and
    /// strip widths on a reduced-resolution image. Returns scored results.
    ///
    /// Strip width handling:
    /// - A value of 0 means "full image width" and is always kept as-is.
    /// - Other values are scaled down by shrinkFactor for the reduced-res search,
    ///   with a minimum of 20 pixels at reduced resolution.
    /// - To ensure different full-res strip widths produce meaningfully different
    ///   reduced-res strip widths, we deduplicate shrunk widths. When multiple
    ///   full-res values map to the same shrunk width, we keep only the largest
    ///   full-res value (since it will produce the same reduced-res result but
    ///   will perform better at full resolution).
    private func runScoredHorizonSearch(
      cropAmounts: [Double],
      shrunkImage: PixelatedImage,
      shrunkEdgeImage: PixelatedImage?,
      shrunkWidth: UInt,
      config: Config
    ) async throws -> [HorizonSearchResult] {
        // Deduplicate: when multiple full-res widths map to the same shrunk width,
        // keep only the largest full-res width (it produces the same reduced-res
        // result but will work better at full resolution).
        // The special value 0 (full width) is always kept as a separate entry.

        return try await withThrowingTaskGroup(
          of: Optional<HorizonSearchResult>.self
        ) { taskGroup in
            for cropAmount in cropAmounts {
                taskGroup.addTask { [frameIndex] in
                    if let mask = try await shrunkImage.horizonMask(
                            at: frameIndex,
                            bottomPercentage: cropAmount,
                            useCannyEdgeDetection: config.useCannyForHorizonDetection,
                            cannyMinThreshold: config.cannyMinThreshold,
                            cannyMaxThreshold: config.cannyMaxThreshold,
                            useL2Gradient: config.cannyUseL2Gradient
                          )
                    {

                        // The crop boundary is the first row of the cropped region
                        // in the mask's coordinate space.  The mask has the same
                        // height as the shrunk image; the top `cropAmount`% rows
                        // were assumed to be sky and were filled white (not processed
                        // by Otsu). The boundary between assumed-sky and the Otsu
                        // region sits at this Y coordinate.
                        let shrunkCropBoundaryY = Int(Double(shrunkImage.height) * cropAmount / 100.0)

                        let score: HorizonScore
                        if let edges = shrunkEdgeImage {
                            score = HorizonScoring.score(
                              horizonMask: mask,
                              edgeImage: edges,
                              cropBoundaryY: shrunkCropBoundaryY
                            )
                        } else {
                            score = HorizonScoring.score(
                              horizonMask: mask,
                              originalImage: shrunkImage,
                              cannyMinThreshold: config.cannyMinThreshold,
                              cannyMaxThreshold: config.cannyMaxThreshold,
                              useL2Gradient: config.cannyUseL2Gradient,
                              cropBoundaryY: shrunkCropBoundaryY
                            )
                        }

                        return HorizonSearchResult(
                          cropAmount: cropAmount,
                          horizonMask: mask,
                          score: score
                        )
                    }
                    return nil
                }
            }

            var results: [HorizonSearchResult] = []
            for try await result in taskGroup {
                if let result { results.append(result) }
            }
            return results
        }
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
    
    // uses opencv2 for dark ground specific detection logic
    private func loadOrCreateEarthAlignedImage() async throws -> WarpedImageResult {
        try await loadOrCreateAlignedImage(
          of: .earthAligned,
          withFailedType: .failedEarthAligned
        )
    }
    
    // uses opencv2 for SIFT fast, accurate image alignment
    private func loadOrCreateStarAlignedImage() async throws -> WarpedImageResult {
        try await loadOrCreateAlignedImage(
          of: .starAligned,
          withFailedType: .failedStarAligned
        )
    }

    // XXX break this up into:
    // - get and save neighbor homography
    // - align neighbors with given homography

    /*

     This method expects homography to have been computed for all neighbors
     and stored in neighborStarHomography or neighborEarthHomography
     
     */
    fileprivate func loadOrCreateAlignedImage(
      of type: FrameViewMode,
      withFailedType failedType: FrameViewMode? = nil
    ) async throws -> WarpedImageResult {
        var alignmentType: AlignmentType = .sky

        // Gate on memory before loading full-resolution images for alignment.
        // Each aligned image is roughly width × height × cpp × 2 bytes (16-bit).
        let estimatedBytes = MemoryMonitor.estimatedImageBytes(
            width: width,
            height: height,
            componentsPerPixel: componentsPerPixel
        )
        await MemoryMonitor.shared.waitForMemory(needed: estimatedBytes)

        Log.d("frame \(frameIndex) loadOrCreateAlignedImage of type \(type)")
        
        switch type {
        case .starAligned:
            alignmentType = .sky
        case .earthAligned:
            alignmentType = .earth
        default:
            throw "unable to loadOrCreateAlignedImage of type \(type)"
        }

        // load or create the aligned frame
        if let alignedFrame = try await imageAccessor.load(
             frameIndex: frameIndex,
             type: type,
             atSize: .original
           )
        {
            Log.d("frame \(frameIndex) loaded aligned frame")
            
            let horizonMask = try await self.loadOrCreateMergedHorizonMask()
            var results: HomographyResultsCodable? = nil
            switch alignmentType {
            case .earth:
                results = await self.readEarthNeighborHomographyForThisFrame()
                if let results {
                    await observer?.set(earthAlignmentResults: results)
                }
            case .sky:
                results = await self.readStarNeighborHomographyForThisFrame()
                if let results {
                    await observer?.set(starAlignmentResults: results)
                }
            default:
                break
            }

            return WarpedImageResult(
              warpedFrame: alignedFrame.mat,
              warpedHorizon: horizonMask?.image.mat
            )
        } else {
            Log.d("frame \(frameIndex) unable to load image of type \(type)")
            if let failedType {
                if let failedFrame = try await imageAccessor.load(
                     frameIndex: frameIndex,
                     type: failedType,
                     atSize: .original
                   )
                {
                    Log.d("frame \(frameIndex) trying to load image of type \(failedType) because we were unable to load image of type \(type)")
                    let horizonMask = try await self.loadOrCreateMergedHorizonMask()
                    var results: HomographyResultsCodable? = nil
                    switch alignmentType {
                    case .earth:
                        results = await self.readEarthNeighborHomographyForThisFrame()
                        if let results {
                            await observer?.set(earthAlignmentResults: results)
                        }
                    case .sky:
                        results = await self.readStarNeighborHomographyForThisFrame()
                        if let results {
                            await observer?.set(starAlignmentResults: results)
                        }
                    default:
                        break
                    }                
                    Log.d("frame \(frameIndex) successfully loaded failed image of type \(failedType)")

                    return WarpedImageResult(
                      warpedFrame: failedFrame.mat, 
                      warpedHorizon: horizonMask?.image.mat
                    )
                } else {
                    Log.w("frame \(frameIndex) unable to load image of failed type \(failedType) when missing image of type \(type)")
                }
            } else {
                Log.w("frame \(frameIndex) no failed type to load when missing image of type \(type)")
            }
        }
        // with no saved aligned frame, first load or create the set of aligned frames
        // that we used to create the final aligned frame

        Log.i("frame \(frameIndex) creating aligned image of type \(type)")
        
        let config = await configManager.config()

        switch type {
        case .starAligned:
            self.set(state: .starAlignment(.start))
        case .earthAligned:
            if config.tripodHeadWasMoving {
                self.set(state: .earthAlignment(.start))
            }
        default:
            break
        }

        guard let originalFrame = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original)
        else {
            throw "frame \(frameIndex) unable to load original frame for star alignment"
        }

        if originalFrame.isEmpty { Log.w("EMPTY IMAGE") }

        Log.d("frame \(frameIndex) original frame \(originalFrame.description)")

        var neighbors: [AlignmentNeighborInfo] = []
        
        for neighborIndex in alignmentFilenames.keys {
            if let filename = self.imageAccessor.nameForImage(
                 frameIndex: neighborIndex,
                 ofType: .original,
                 atSize: .original
               )
            {
                // load any possible keypoints for this neighbor 
                var keypointFilename = ""
                
                switch type {
                case .starAligned:
                    keypointFilename = "\(neighborIndex).sky.yaml"
                case .earthAligned:
                    keypointFilename = "\(neighborIndex).earth.yaml"
                default:
                    Log.e("not loading keypoints for type \(type)")
                }

                let keypoints = OCVFeatureSet.load(
                  fromFilename: "\(config.dirForKeypointData)/\(keypointFilename)"
                )
                
                switch alignmentType {
                case .earth:
                    if let maskFilename = self.imageAccessor.nameForImage(
                         frameIndex: neighborIndex,
                         ofType: .horizon,
                         atSize: .original
                       )
                    {
                        neighbors.append(
                          AlignmentNeighborInfo(
                            filename: filename,
                            maskFilename: maskFilename,
                            keypoints: keypoints,
                            frameIndex: Int32(neighborIndex)
                          )
                        )
                    } else {
                        Log.w("frame \(frameIndex) unable to get filename mask original image at frame index \(neighborIndex)")
                    }
                case .sky:
                    neighbors.append(
                      AlignmentNeighborInfo(
                        filename: filename,
                        maskFilename: nil,
                        keypoints: keypoints,
                        frameIndex: Int32(neighborIndex)
                      )
                    )
                default:
                    break
                }
            } else {
                Log.w("frame \(frameIndex) unable to get filename for original image at frame index \(neighborIndex)")
            }
        }

        Log.d("frame \(frameIndex) original frame \(originalFrame.description)")
        
        var warpedResult: WarpedImageResult? = nil

        let pixelThreshold = await self.pixelThreshold
        
        if alignmentType == .earth,
           !config.tripodHeadWasMoving
        {
            Log.d("frame \(frameIndex) not aliging earth, just merging") 
            // don't try to align if we're combining not moving earth,
            // just median merge them all

            if let mergedImage = originalFrame.medianMerge(
                 with: self.getStaticNeighborFilenames(),
                 outlierThreshold: pixelThreshold
               )
            {
                var horizonMask: HorizonMask? = nil
                if config.horizonDetectionEnabled {
                    // use static merged horizons  
                    horizonMask = try await loadOrCreateMergedHorizonMask()
                }
                
                warpedResult = WarpedImageResult(
                  warpedFrame: mergedImage.mat,
                  warpedHorizon: horizonMask?.image.mat
                )
            }
        } else {
            // tripod head is moving or stars, do full alignment
            var horizonMask: HorizonMask? = nil
            if config.horizonDetectionEnabled {
                Log.d("frame \(frameIndex) calling loadFinalHorizonMask()")
                horizonMask = try await loadOrCreateFinalHorizonMask()
                if let horizonMask {
                    Log.d("horizon mask \(horizonMask.image.description)")
                }
            }
            
            Log.d("frame \(frameIndex) doing real alignment for type \(alignmentType)")
            // do real alignment
            var homography: [Int: MatWrapper]? = nil
            switch type {
            case .starAligned:
                homography = neighborStarHomography?.mappedHomography()
            case .earthAligned:
                homography = neighborEarthHomography?.mappedHomography()
            default:
                break
            }
            Log.d("frame \(frameIndex) using homography \(homography as Any)")
            if let homography {
                let result = ImageAligner.align(
                  baseFrameIndex: Int32(frameIndex),
                  neighbors: neighbors,
                  homography: homography
                )

                if !result.isEmpty {
                    Log.d("frame \(frameIndex) got \(result.count) results back from alignment")

                    // include the original frame so we don't miss any edges
                    var imagesToMerge: [MatWrapper] = [originalFrame.mat]

                    // merge in all the warped neighbor frames
                    imagesToMerge += result.compactMap { $0.warpedFrame }

                    // median merge the frames and package as a result
                    warpedResult = WarpedImageResult(
                      warpedFrame: ImageAligner.medianMerge(
                        imagesToMerge,
                        outlierThreshold: config.pixelThreshold,
                        includeAll: false
                      ),
                      warpedHorizon: nil // XXX
                    )
                } else {
                    Log.w("frame \(frameIndex) alignment returned no results")
                }
            } else {
                Log.w("frame \(frameIndex) cannot align without homography")
            }
        }
        Log.i("frame \(frameIndex) got alignment result \(warpedResult as Any) for type \(type)")
        guard let warpedResult else {
            Log.e("frame \(frameIndex) got no alignment result")
            // XXX report his error to the UI
            return WarpedImageResult(
              warpedFrame: originalFrame.mat, 
              warpedHorizon: nil
            )
        }
        
        switch type {
        case .starAligned:
            self.set(state: .creatingStarAlignedFrame)
        case .earthAligned:
            self.set(state: .creatingEarthAlignedFrame)
        default:
            break
        }
         
        if let aligned = warpedResult.warpedFrame,
           let image = PixelatedImage(mat: aligned)
        {
            // write out the successfully aligned images
            Log.i("frame \(frameIndex) writing out a successfully aligned image of type \(type)")
            try await imageAccessor.save(
              image,
              frameIndex: frameIndex,
              as: type,
              atSizes: [.original, .preview],
              overwrite: true
            )
        }
        
        if let mergedHorizon = warpedResult.warpedHorizon,
           let image = PixelatedImage(mat: mergedHorizon)
        {
            Log.d("saving merged horizon images")
            try await imageAccessor.save(
              image,
              frameIndex: frameIndex,
              as: .mergedHorizon,
              atSizes: await self.outputSizes,
              overwrite: true
            )
        }

        return warpedResult
    }    

    private var neighborEarthHomography: HomographyResultsCodable? = nil
    private var neighborStarHomography: HomographyResultsCodable? = nil

    public func set(neighborStarHomography: HomographyResultsCodable) {
        self.neighborStarHomography = neighborStarHomography
        do {
            try self.write(neighborStarHomography: neighborStarHomography.neighborHomography)
            Log.i("frame \(frameIndex) set star homography: \(neighborStarHomography.neighborHomography)")
        } catch {
            Log.e("frame \(frameIndex) unable to set star homography: \(error)")
        }
    }
    
    public func set(neighborEarthHomography: HomographyResultsCodable) {
        self.neighborEarthHomography = neighborEarthHomography
        do {
            try self.write(neighborEarthHomography: neighborEarthHomography.neighborHomography)
        } catch {
            Log.e("frame \(frameIndex) unable to set star homography: \(error)")
        }
    }
    
    public func getNeighborStarHomography() -> HomographyResultsCodable? {
        neighborStarHomography
    }
    
    public func getNeighborEarthHomography() -> HomographyResultsCodable? {
        neighborEarthHomography
    }
    
    internal func loadOrCreateHomography(
      of type: FrameViewMode
    ) async throws -> HomographyResultsCodable? {
        var alignmentType: AlignmentType = .sky

        Log.d("frame \(frameIndex) loadOrCreateHomography of type \(type) ")
        
        switch type {
        case .starAligned:
            alignmentType = .sky
        case .earthAligned:
            alignmentType = .earth
        default:
            throw "unable to load homography of type \(type)"
        }

        // try to load from ram/file first
        switch alignmentType {
        case .sky:
            if let ret = neighborStarHomography {
                // from ram
                return ret
            } else if let results = await self.readStarNeighborHomographyForThisFrame() {
                // from file
                let ret = HomographyResultsCodable(for: frameIndex, with: results.neighborHomography)
                self.neighborStarHomography = ret
                return ret
            }
        case .earth:
            if let ret = neighborEarthHomography {
                // from ram
                return ret
            } else if let results = await self.readEarthNeighborHomographyForThisFrame() {
                // from file
                let ret = HomographyResultsCodable(for: frameIndex, with: results.neighborHomography)
                self.neighborEarthHomography = ret
                return ret
            }
        default:
            break
        }

        // cached loads failed
        
        // with no saved homography, calculate it from given feature points
        // of both this frame and all relevant neighboring frames.

        Log.i("frame \(frameIndex) creating aligned image of type \(type)")
        
        let config = await configManager.config()

        switch type {
        case .starAligned:
            self.set(state: .starAlignment(.start))
        case .earthAligned:
            if config.tripodHeadWasMoving {
                self.set(state: .earthAlignment(.start))
            }
        default:
            break
        }

        var neighbors: [AlignmentNeighborInfo] = []
        
        for neighborIndex in alignmentFilenames.keys {
            if let filename = self.imageAccessor.nameForImage(
                 frameIndex: neighborIndex,
                 ofType: .original,
                 atSize: .original
               )
            {
                // load any possible keypoints for this neighbor 
                var keypointFilename = ""
                
                switch type {
                case .starAligned:
                    keypointFilename = "\(neighborIndex).sky.yaml"
                case .earthAligned:
                    keypointFilename = "\(neighborIndex).earth.yaml"
                default:
                    Log.e("not loading keypoints for type \(type)")
                }

                let keypoints = OCVFeatureSet.load(
                  fromFilename: "\(config.dirForKeypointData)/\(keypointFilename)"
                )
                switch alignmentType {
                case .earth:
                    if let maskFilename = self.imageAccessor.nameForImage(
                         frameIndex: neighborIndex,
                         ofType: .horizon,
                         atSize: .original
                       )
                    {
                        neighbors.append(
                          AlignmentNeighborInfo(
                            filename: filename,
                            maskFilename: maskFilename,
                            keypoints: keypoints,
                            frameIndex: Int32(neighborIndex)
                          )
                        )
                    } else {
                        Log.w("frame \(frameIndex) unable to get filename mask original image at frame index \(neighborIndex)")
                    }
                case .sky:
                    neighbors.append(
                      AlignmentNeighborInfo(
                        filename: filename,
                        maskFilename: nil,
                        keypoints: keypoints,
                        frameIndex: Int32(neighborIndex)
                      )
                    )
                default:
                    break
                }
            }
        }

        // can't load from file, detect homography 

        Log.d("frame \(frameIndex) doing real alignment for type \(alignmentType)")
        // do real alignment

        var baseKeypoints: OCVFeatureSet? = nil

        switch alignmentType {
        case .sky:
            baseKeypoints = self.skyKeyPoints
        case .earth:
            baseKeypoints = self.earthKeyPoints
        default:
            break
        }

        if baseKeypoints == nil {
            Log.w("frame \(frameIndex) didn't have keypoints in ram for alignment type \(alignmentType), trying to load or create them")
            baseKeypoints = try await loadOrCreateOCVFeatures(of: type) 
        }

        guard let baseKeypoints else {
            Log.w("frame \(frameIndex) has no base keypoints for alignment type \(alignmentType)")
            return nil
        }

        Log.d("frame \(frameIndex) has base keypoints \(baseKeypoints) and \(neighbors.count) neighbors")
        
        if let result = ImageAligner.computeHomography(
             baseKeypoints: baseKeypoints,
             frameIndex: Int32(frameIndex),
             neighbors: neighbors,
             matchMethod: .FLANN, //.bruteForce,//.FLANN,//.knnLowes,
             alignmentType: alignmentType,
             maxKeypoints: Int32(config.alignmentMaxKeypoints),
             writeDebugImages: config.alignmentWriteDebugImages,
             handler: { frameIndex,
                        alignmentType,
                        alignmentStep,
                        neighborNumber in

                 // XXX this handler is out of date now

                 Log.d("frame \(frameIndex) got alignment step update \(alignmentStep)")
                 // update frame state while processing
                 var processingState: FrameProcessingState? = nil

                 if let step = AlignmentStep(
                      from: alignmentStep,
                      neighborNumber: Int(neighborNumber))
                 {
                     switch alignmentType {
                     case .sky:
                         processingState = .starAlignment(step)
                     case .earth:
                         processingState = .earthAlignment(step)
                     default:
                         break
                     }
                 } else {
                     Log.w("frame \(frameIndex) unable to process alignment step \(alignmentStep)")
                 }

                 if let processingState {
                     Log.d("frame \(frameIndex) setting processingState \(processingState)")
                     self.set(state: processingState)
                 }
             })
        {
            Log.d("frame \(frameIndex) got homography result \(result)")
            let alignedWarps = result.warpInfo.map { $0.toCodable() }
            Log.d("frame \(frameIndex) alignedWarps \(alignedWarps)")
            
            let ret = HomographyResultsCodable(from: result)

            // save homography results for later
            switch type {
            case .starAligned:
                try self.write(
                  neighborStarHomography: alignedWarps
                )
                // store results in ram for lookup later
                self.neighborStarHomography = ret
            case .earthAligned:
                try self.write(
                  neighborEarthHomography: alignedWarps
                )
                // store results in ram for lookup later
                self.neighborEarthHomography = ret
            default:
                break
            }

            return ret
        }
        
        return nil
    }
    
    // uses opencv2 for dark ground specific detection logic
    public func loadOrCreateEarthFeatures() async throws -> OCVFeatureSet? {
        if let earthKeyPoints {
            return earthKeyPoints
        } else {
            self.earthKeyPoints = try await loadOrCreateOCVFeatures(of: .earthAligned)
            return self.earthKeyPoints
        }
    }
    
    // uses opencv2 for SIFT fast, accurate image alignment
    public func loadOrCreateStarFeatures() async throws -> OCVFeatureSet? {
        if let skyKeyPoints {
            Log.d("frame \(frameIndex) returning \(skyKeyPoints) skyKeyPoints")
            return skyKeyPoints
        } else {
            self.skyKeyPoints = try await loadOrCreateOCVFeatures(of: .starAligned)
            Log.d("frame \(frameIndex) loaded \(self.skyKeyPoints as Any) skyKeyPoints")
            return self.skyKeyPoints
        } 
    }

    // key points detected in the image are OpenCV features 
    func loadOrCreateOCVFeatures(
      of type: FrameViewMode
    ) async throws -> OCVFeatureSet? {
        var alignmentType: AlignmentType = .sky

        Log.d("frame \(frameIndex) loadOrCreateOCVFeatures")
        var filename = ""
          
        switch type {
        case .starAligned:
            alignmentType = .sky
            filename = "\(frameIndex).sky.yaml"
        case .earthAligned:
            alignmentType = .earth
            filename = "\(frameIndex).earth.yaml"
        default:
            throw "unable to loadOrCreateOCVFeatures of type \(type)"
        }

        // load or create the features

        // try to load first
        let config = await configManager.config()

        let fullPath = "\(config.dirForKeypointData)/\(filename)"
        if let features = OCVFeatureSet.load(fromFilename: fullPath) {
            return features
        }

        // with no saved features, find them
        // that we used to create the final aligned frame

        Log.i("frame \(frameIndex) creating aligned image of type \(type)")
        switch type {
        case .starAligned:
            self.set(state: .starKeypoints)
        case .earthAligned:
            self.set(state: .earthKeypoints)
        default:
            break
        }

        guard let originalFrame = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original)
        else {
            throw "frame \(frameIndex) unable to load original frame for keypoint detection"
        }

        if originalFrame.isEmpty { Log.w("EMPTY IMAGE") }

        Log.d("frame \(frameIndex) original frame \(originalFrame.description)")

        var horizonMask: HorizonMask? = nil
        if config.horizonDetectionEnabled {
            horizonMask = try await loadOrCreateFinalHorizonMask()
            if let horizonMask {
                Log.d("horizon mask \(horizonMask.image.description)")
            }
        }
        
        Log.d("frame \(frameIndex) finding keypoints of type \(alignmentType)")

        // SIFT builds a multi-octave Gaussian scale-space pyramid that uses
        // substantially more memory than the image itself.  Gate here so concurrent
        // keypoint operations don't collectively exhaust RAM.
        // The 8x multiplier is empirically derived: ~2.5 GB observed per 42 MP frame.
        let siftMemoryEstimate = UInt64(originalFrame.byteCount) * 8
        await MemoryMonitor.shared.waitForMemory(needed: siftMemoryEstimate)

        if let results = ImageAligner.findFeatures(
             baseImage: originalFrame.mat,
             frameIndex: Int32(frameIndex),
             matchMethod: .FLANN, //.bruteForce,//.FLANN,//.knnLowes,
             mask: horizonMask?.image.mat,
             alignmentType: alignmentType,       // earth is zero in mask
             maxKeypoints: Int32(config.alignmentMaxKeypoints),
             writeDebugImages: config.alignmentWriteDebugImages,
             groundHorizonExtension: Int32(config.alignmentGroundHorizonExtension),
             baseImageDilateSize: Int32(config.alignmentBaseImageDilateSize),
             baseImageThresholdValue: Int32(config.alignmentBaseImageThresholdValue)
           )
        {
            Log.d("frame \(frameIndex) got \(results.keypointCount) keypoints")

            if results.write(toFilename: fullPath) {
                Log.d("frame \(frameIndex) wrote results to \(fullPath)")
            } else {
                Log.w("frame \(frameIndex) failed to write results to \(fullPath)")
            }

            // save results in RAM
            switch type {
            case .starAligned:
                self.skyKeyPoints = results
            case .earthAligned:
                self.earthKeyPoints = results
            default:
                throw "unknown type \(type)"
            }

            return results
        }
        return nil
    }    
    
    let neighborStarHomographyFilename = "neighbor_star_homography.json"

    public func removeNeighborStarHomography() throws {
        if FileManager.default.fileExists(atPath: neighborStarHomographyFilename) {
            try FileManager.default.removeItem(atPath: neighborStarHomographyFilename)
        }
    }
    
    private func write(
      neighborStarHomography: [AlignmentWarpInfoCodable]
    ) throws {
        Log.d("frame \(frameIndex) writing \(neighborStarHomography.count) neighborStarHomographies")
        if let results = try write(
             homography: neighborStarHomography,
             to: neighborStarHomographyFilename
           ),
           let observer
        {
            Log.d("frame \(frameIndex) notifying observer of star alignment results")
            Task { await observer.set(starAlignmentResults: results) }
        }
    }

    private func write(
      homography: [AlignmentWarpInfoCodable],
      to filename: String
    ) throws -> HomographyResultsCodable? {
        if let dirname = imageAccessor.dirForImage(
          ofType: .starAligned,
          atSize: .original
        ) {
            Log.d("frame \(frameIndex) write \(homography.count) homographies to \(filename)")
            let dirname = "\(dirname)/\(frameIndex)"
            StarCore.mkdir(dirname)
            // write a text file with

            let results = HomographyResultsCodable(
              for: frameIndex,
              with: homography
            )
            
            let encoder = JSONEncoder()
            do {
                let jsonData = try encoder.encode(results)
                
                let fullPath = "\(dirname)/\(filename)"
                if FileManager.default.fileExists(atPath: fullPath) {
                    try FileManager.default.removeItem(atPath: fullPath)
                } 
                Log.i("creating \(fullPath)")                      
                _ = FileManager.default.createFile(
                  atPath: fullPath,
                  contents: jsonData,
                  attributes: nil
                )
            } catch {
                Log.e("\(error)")
            }
            return results
        } else {
            return nil
        }
    }
    
    public func readStarNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await readHomographyResults(from: neighborStarHomographyFilename)
    }

    private func readHomographyResults(from filename: String) async -> HomographyResultsCodable? {
        if let dirname = imageAccessor.dirForImage(ofType: .starAligned,
                                                   atSize: .original)
        {
            do {
                let dirname = "\(dirname)/\(frameIndex)"
                StarCore.mkdir(dirname)

                let fullPath = "\(dirname)/\(filename)"
                let url = NSURL(
                  fileURLWithPath: fullPath,
                  isDirectory: false
                ) as URL
                
                let (data, _) = try await URLSession.shared.data(
                  for: URLRequest(
                       url: url
                     )
                )
                let decoder = JSONDecoder()
                return try decoder.decode(HomographyResultsCodable.self, from: data)
            } catch {
                //Log.i("Error: \(error)")
                return nil
            }
        }
        return nil
    }
    
    public func removeNumberOfAlignedImagesForThisFrameFile() throws {
        // get rid of any existing .txt files
        if let dirname = imageAccessor.dirForImage(ofType: .starAligned,
                                                   atSize: .original)
        {
            let dirname = "\(dirname)/\(frameIndex)"
            StarCore.mkdir(dirname)
            try? removeFiles(withSuffix: ".json", in: dirname)
        } 
    }
        
    let neighborEarthHomographyFilename = "neighbor_earth_homography.json"

    private func write(
      neighborEarthHomography: [AlignmentWarpInfoCodable]
    ) throws {
        if let results = try write(
             homography: neighborEarthHomography,
             to: neighborEarthHomographyFilename
           ),
           let observer
        {
            Task { await observer.set(earthAlignmentResults: results) }
        }
    }


    public func readEarthNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await readHomographyResults(from: neighborEarthHomographyFilename)
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

    public func getAlignmentFrameIndices() -> [Int] {
        alignmentFrames
    }
    
    private var alignmentFrames: [Int] = []
    private var staticNeighborFrames: [Int] = []

    public func getStaticNeighborFrames() -> [Int] { staticNeighborFrames }

    public func getStaticNeighborFilenames() -> [String] {
        var ret: [String] = []
        for neighborIndex in staticNeighborFrames {
            if let filename = self.imageAccessor.nameForImage(
                 frameIndex: neighborIndex,
                 ofType: .original,
                 atSize: .original
               )
            {
                ret.append(filename)
            }
        }
        return ret
    }

    // the filenames of the original files that we should align with this frame
    private var alignmentFilenames: [Int:String] {
        guard let imageSequence else {
            Log.e("cannot get alignemnt frames images without an image sequence")
            return [:]
        }
        var ret: [Int:String] = [:]
        for alignmentFrame in alignmentFrames {
            if alignmentFrame < imageSequence.filenames.count {
                ret[alignmentFrame] = imageSequence.filenames[alignmentFrame]
            }
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

    // called from the CLI only, not the GUI
    public func setupOutliers() async throws {
        // this takes a long time, and the gui does it later
        try await loadOutliers()
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
            let result = try await loadOrCreateEarthAlignedImage()
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
                horizonMask = try await loadOrCreateFinalHorizonMask()
            }
        }

        let alignmentResult = try await loadOrCreateStarAlignedImage()
        
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
                if let outlierGroups {
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

    // Mark - Outliers
    

    // loads outliers from a combination of the outliers.tiff image and the subtraction image,
    // if they are present
    public func loadOutliersFromFile() async -> OutlierGroups? {
        try? await outliersFileSystemMonitor.load() {
            do {
                // newer file format, default to this
                return try await loadOutliersFromBinaryFile()
            } catch {
                //Log.i("frame \(frameIndex) failed to load outliers: \(error)")
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

        return try await OutlierGroups(
          at: frameIndex,
          fromOutlierDir: dirname,
          config: config
        )
    }
    
    // re-runs outlier detection within bounds with current settings
    public func findOutliers(within bounds: BoundingBox) async throws {
        Log.d("shovel frame \(frameIndex) finding outliers within bounds \(bounds)")

        if outlierGroups == nil {
            self.outlierGroups = OutlierGroups(
              frameIndex: self.frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else {
            Log.e("cannot find outliers without outlier groups")
            return
        }
        
        mkdir(await self.outliersDirname)

        let blobProcessor = await constants.getDetectionType().blobProcessor

        let currentMaxID = await outlierGroups.maxID

        Log.i("frame \(frameIndex) found currentMaxID \(currentMaxID)")
        
        let newBlobMap = try await blobProcessor.process(
          frame: self,
          within: bounds,
          startingBlobID: currentMaxID + 1
        )

        // add new blobs to outlier groups, fore-going any classification for now
        await outlierGroups.add(blobs: newBlobMap, within: bounds)

        try await outlierGroups.writeOutliersBinary(to: self.outliersDirname)
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
            if let outlierGroups = await loadOutliersFromFile() {
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
                await self.initializeEmptyOutlierGroups()

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

    public func initializeEmptyOutlierGroups() async {
        self.outlierGroups = OutlierGroups(
          frameIndex: frameIndex,
          config: await configManager.config()
        )
    }
    
    public func foreachOutlierGroup(
      includingTrash: Bool,
      _ closure: @Sendable (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        var didChange = false
        if let outlierGroups {
            for (_, group) in await outlierGroups.getMembers() {
                if await closure(group, false) { didChange = true }
            }
            if includingTrash {
                for (_, group) in await outlierGroups.getTrash() {
                    if await closure(group, true) { didChange = true }
                }
            }
        }
        return didChange
    }

    // returns true if any outlier group was changed
    public func foreachOutlierGroupMulti(
      includingTrash: Bool,
      _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        var didChange = false
        if let outlierGroups {
            didChange = await Task.detached(priority: .userInitiated) {

                let outliers = await Array(outlierGroups.getMembers().values)
                var trash: [OutlierGroup] = []

                if includingTrash {
                    trash = await Array(outlierGroups.getTrash().values)
                }
                return await foreachOutlier(in: outliers, with: trash, closure)
            }.value
        }
        return didChange
    }

    public func outlierGroup(named outlierName: UInt16) async -> OutlierGroup? {
        await outlierGroups?.getMembers()[outlierName]
    }

    // returns true if anything changed 
    public func foreachOutlierGroupMulti(
      between startLocation: CGPoint,
      and endLocation: CGPoint,
      includingTrash: Bool, 
      _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool
    ) async -> Bool {
        // first get bounding box from start and end location
        var minX: CGFloat = CGFloat.greatestFiniteMagnitude
        var maxX: CGFloat = 0
        var minY: CGFloat = CGFloat.greatestFiniteMagnitude
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
        
        return await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
            var didChange = false
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change removal status
                if !isInTrash || (includingTrash && isInTrash) {
                    if await closure(group, isInTrash) { didChange = true }
                }
            }
            return didChange
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
            await self.applyDecisionTreeToAllOutliers()
        }
    }

    // used to classify outliers given a validation image.
    // this validation image contains a non zero pixel for each outlier
    // that should be removed.
    // any outlier that matches any pixels is classified to remove here.
    private func classifyOutliers(with validationData: UnsafeBufferPointer<UInt8>) async {
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
                _ = await group.shouldRemove(.userSelected(groupIsValid))
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
        var blobImageData = ImageBuffer<UInt8>(width: width, height: height)
        for blob in blobs {
            for pixel in await blob.getPixels() {
                let imageIntensity = pixel.uInt16Value >> 8
                blobImageData[pixel.y*width+pixel.x] = UInt8(imageIntensity)//0xFF // make different per blob?
            }
        }
        let fuck = frameImageType
        if let blobImage = blobImageData.image {

            let (_) = await (/*try imageAccessor.save(blobImage, as: fuck,
                               atSize: .original, overwrite: true),*/
              try imageAccessor.save(blobImage,
                                     frameIndex: frameIndex,
                                     as: fuck,
                                     atSize: .preview, overwrite: true))
        } else {
            Log.w("frame \(frameIndex) unable to get blob image to save")
        }
        
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
            _ = FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
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
        if outlierGroups == nil {
            self.outlierGroups = OutlierGroups(
              frameIndex: self.frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else { return [] }
        let ret = await outlierGroups.promoteDust(in: boundingBox)

        await self.markAsChanged()
        await updateCombineSubjects()
        
        try await outlierGroups.writeOutliersBinary(to: self.outliersDirname)

        return ret
    }

    public func deleteHorizonImages() {
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .horizon,
          atSize: .preview
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .horizon,
          atSize: .original
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .mergedHorizon,
          atSize: .preview
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .mergedHorizon,
          atSize: .original
        )

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
        guard let outlierGroups = outlierGroups else {
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
        guard let outlierGroups = outlierGroups else {
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

    // Mark - UI

    /*
     UI related methods
     */
    
    public func applyDecisionTreeToAutoSelectedOutliers(includingTrash: Bool,
                                                        overwrite: Bool = false,
                                                        minimumSize: Int? = nil) async {
        if let classifier = await currentClassifier.get(for: .all) {
            _ = await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                if let minimumSize,
                   group.size < minimumSize { return false }
                
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
                var didChange = false
                if apply {
                    Log.d("applying decision tree")
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                        didChange = true
                    }
                    if await group.shouldRemove(.fromClassifier(await classifier.classification(of: group))) { didChange = true }
                }
                return didChange
            }
        } else {
            Log.w("no classifier")
        }
    }

    public func clearOutlierGroupValueCaches(includingTrash: Bool) async {
        _ = await foreachOutlierGroupMulti(includingTrash: includingTrash) { group, _ in
            await group.clearFeatureValueCache()
            return false
        }
    }

    public func applyDecisionTreeToAllOutliers(
      overwrite: Bool = true,
      minimumSize: Int? = nil
    ) async {
      Log.d("frame \(self.frameIndex) applyDecisionTreeToAll \(await self.outlierGroups?.members.count ?? 0) Outliers")
        let startTime = Date().timeIntervalSince1970
        if let outlierGroups {
            let groups = await outlierGroups.getMembers()
            await Task.detached(priority: .userInitiated) {
                let classifier = OutlierClassifier(frame: self)

                var values = Array(groups.values)

                if let minimumSize {
                    values = values.filter { $0.size > minimumSize }
                }
                
                await classifier.classifyAll(values, overwrite: overwrite)
                let endTime = Date().timeIntervalSince1970
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
                                      includingTrash: Bool) async -> Bool
    {
        let didChange = await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                var didChange = false
                if isInTrash {
                    await self.outlierGroups?.promoteFromTrash(group)
                    didChange = true
                }
                if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
                return didChange
            }
        }.value
        Task { @MainActor in
            if didChange {
                await self.markAsChanged() // only mark as changed if we have changed something
            }
            await self.updateCombineSubjects()
        }
        return didChange
    }

    public func userSelectUndecidedOutliers(toShouldRemove shouldRemove: Bool,
                                            includingTrash: Bool) async -> Bool
    {
        let didChange = await Task.detached(priority: .userInitiated) {
            await self.foreachOutlierGroupMulti(includingTrash: includingTrash) { group, isInTrash in
                var didChange = false
                if await group.shouldRemove() == nil {
                    if isInTrash {
                        await self.outlierGroups?.promoteFromTrash(group)
                        didChange = true
                    }
                    if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
                }
                return didChange
            }
        }.value
        Task { @MainActor in
            if didChange {
                await self.markAsChanged()
            }
            await self.updateCombineSubjects()
        }
        return didChange
    }

    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      overlapping group: OutlierGroup) async -> Bool
    {
        if outlierGroups == nil {
            self.outlierGroups = OutlierGroups(
              frameIndex: self.frameIndex,
              config: await configManager.config()
            )
        }
        
        guard let outlierGroups else { return false }

        var didChange = false
        for group in await outlierGroups.groups(overlapping: group) {
            if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
        }
        Task { @MainActor in
            if didChange {
                await self.markAsChanged()
            }
            await self.updateCombineSubjects()
        }
        return didChange
    }
    
    public func userSelectAllOutliers(toShouldRemove shouldRemove: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint,
                                      includingTrash: Bool) async
    {
        let didChange = await foreachOutlierGroupMulti(
          between: startLocation,
          and: endLocation,
          includingTrash: includingTrash)
        { group, isInTrash in
            var didChange = false
            if isInTrash {
                await self.outlierGroups?.promoteFromTrash(group)
                didChange = true
            }
            if await group.shouldRemove(.userSelected(shouldRemove)) { didChange = true }
            return didChange
        }
        Task { @MainActor in
            if didChange {
                await self.markAsChanged()
            }
            await self.updateCombineSubjects()
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

        let result = try await loadOrCreateStarAlignedImage()
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
                let alignmentResult = try await loadOrCreateEarthAlignedImage()

                // XXX add check to see if the alignment was good, and if so, save it
                // if not, return early
                
                // XXX validate this alignment result, it might be erroneous
                // if it's bad, use the original frame and horizon mask instead

                let earthAlignedImage = alignmentResult.warpedFrame
                if let mat = alignmentResult.warpedHorizon {
                    horizonMask = PixelatedImage(mat: mat)
                } else {
                    horizonMask = try await loadOrCreateFinalHorizonMask()?.image
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

                horizonMask = try await loadOrCreateFinalHorizonMask()?.image
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
                    if let horizonMask = try await loadOrCreateFinalHorizonMask() {
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
                    if let outlierGroups {
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
        let result = try await loadOrCreateStarAlignedImage()
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

            let alignmentResult = try await loadOrCreateEarthAlignedImage()
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
                } else if let mask = try await self.loadOrCreateFinalHorizonMask() {
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
            let startTime = Date().timeIntervalSince1970
            // XXX start time
            
            for (index, outlier) in outliers.enumerated() {
                if index % 100 == 0 {
                    let duration = Date().timeIntervalSince1970 - startTime
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
                                    _ = await group.shouldRemove(.fromClassifier(classification))
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

// closure returns true if an outlier was changed
fileprivate func foreachOutlier(in outliers: [OutlierGroup],
                                with trash: [OutlierGroup],
                                _ closure: @Sendable @escaping (OutlierGroup, Bool) async -> Bool) async -> Bool {
    return await withTaskGroup(of: Bool.self) { taskGroup in
        var didChange = false         // did anything change?
        // max number of concurrent tasks (for each outliers and trash)
        let max = 10            // XXX hardcoded constant

        let outlierChunkSize = outliers.count/max
        let trashChunkSize = trash.count/max

        if outliers.count > 0 {
            for chunk in outliers.chunks(of: outlierChunkSize) {
                taskGroup.addTask() {
                    var didChange = false
                    for group in chunk {
                        if await closure(group, true) { didChange = true }
                    }
                    return didChange
                }
            }
        }
        if trash.count > 0 {
            for chunk in trash.chunks(of: trashChunkSize) {
                taskGroup.addTask() {
                    var didChange = false
                    for group in chunk {
                        if await closure(group, true) { didChange = true }
                    }
                    return didChange
                }
            }
        }
        for await (result) in taskGroup { if result { didChange = true } }
        return didChange
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
