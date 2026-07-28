import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StarCppBridge
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// Owns all image-alignment state for one frame: neighbor indices, keypoints,
// homography transforms, and the aligned-image pipeline.
// Held by FrameAirplaneRemover, which provides the public API and forwards here.
final public actor FrameAlignmentProcessor {

    nonisolated public let frameIndex: Int
    private let width: Int
    private let height: Int
    private let componentsPerPixel: Int
    nonisolated public let imageAccessor: ImageAccessor
    let configManager: ConfigManager
    private weak var imageSequence: ImageSequence?

    // back-reference to the owning frame for state updates, observer
    // notifications, and horizon mask access
    weak var frame: FrameAirplaneRemover?

    private var skyKeyPoints: OCVFeatureSet? = nil {
        didSet {
            Log.d("frame \(frameIndex) did set skyKeyPoints \(skyKeyPoints as Any)")
            Task {
                if let frame {
                    let obs = await frame.getObserver()
                    await obs?.set(numberOfSkyKeyPoints: skyKeyPointCount())
                }
            }
        }
    }

    private var earthKeyPoints: OCVFeatureSet? = nil {
        didSet {
            Task {
                if let frame {
                    let obs = await frame.getObserver()
                    await obs?.set(numberOfEarthKeyPoints: earthKeyPointCount())
                }
            }
        }
    }

    private var neighborEarthHomography: HomographyResultsCodable? = nil
    private var neighborStarHomography: HomographyResultsCodable? = nil

    private var alignmentFrames: [Int] = []
    private var staticNeighborFrames: [Int] = []

    let neighborStarHomographyFilename  = "neighbor_star_homography.json"
    let neighborEarthHomographyFilename = "neighbor_earth_homography.json"

    init(
        frameIndex: Int,
        width: Int,
        height: Int,
        componentsPerPixel: Int,
        imageAccessor: ImageAccessor,
        configManager: ConfigManager,
        imageSequence: ImageSequence?
    ) {
        self.frameIndex = frameIndex
        self.width = width
        self.height = height
        self.componentsPerPixel = componentsPerPixel
        self.imageAccessor = imageAccessor
        self.configManager = configManager
        self.imageSequence = imageSequence
    }

    func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    private var outputSizes: [ImageDisplaySize] {
        get async {
            var sizes: [ImageDisplaySize] = [.original]
            let config = await configManager.config()
            if config.writeFramePreviewFiles { sizes.append(.preview) }
            return sizes
        }
    }

    // MARK: - Accessors

    public func skyKeyPointCount() -> Int {
        if let skyKeyPoints { skyKeyPoints.keypointCount } else { 0 }
    }

    public func earthKeyPointCount() -> Int {
        if let earthKeyPoints { earthKeyPoints.keypointCount } else { 0 }
    }

    public var numberOfAlignedFrames: Int { alignmentFrames.count }

    public func getAlignmentFrameIndices() -> [Int] { alignmentFrames }

    public func getStaticNeighborFrames() -> [Int] { staticNeighborFrames }

    public func getStaticNeighborFilenames() -> [String] {
        var ret: [String] = []
        for neighborIndex in staticNeighborFrames {
            if let filename = imageAccessor.nameForImage(
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

    // MARK: - Neighbor Frame Configuration

    public func setNumberOfStaticNeighborFrames(with config: Config? = nil) async {
        if let config {
            self.staticNeighborFrames = calculateNeighborIndices(config.numberStaticNeighborFrames(for: frameIndex))
        } else {
            let config = await configManager.config()
            self.staticNeighborFrames = calculateNeighborIndices(config.numberStaticNeighborFrames(for: frameIndex))
        }
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
        for index in startFrame..<endFrame {
            if index == frameIndex { continue }
            ret.append(index)
        }
        return ret
    }

    public func getHorizonMergeIndices() async -> [Int] {
        let config = await configManager.config()
        if config.tripodHeadWasMoving {
            return alignmentFrames
        } else {
            return staticNeighborFrames
        }
    }

    // MARK: - Homography

    public func set(neighborStarHomography: HomographyResultsCodable) {
        self.neighborStarHomography = neighborStarHomography
        Log.i("frame \(frameIndex) set star homography: \(neighborStarHomography.neighborHomography)")
        Task {
            do {
                try await self.write(neighborStarHomography: neighborStarHomography.neighborHomography)
            } catch {
                Log.e("frame \(frameIndex) unable to persist star homography: \(error)")
            }
        }
    }

    public func set(neighborEarthHomography: HomographyResultsCodable) {
        self.neighborEarthHomography = neighborEarthHomography
        Task {
            do {
                try await self.write(neighborEarthHomography: neighborEarthHomography.neighborHomography)
            } catch {
                Log.e("frame \(frameIndex) unable to persist earth homography: \(error)")
            }
        }
    }

    public func getNeighborStarHomography() -> HomographyResultsCodable? { neighborStarHomography }

    public func getNeighborEarthHomography() -> HomographyResultsCodable? { neighborEarthHomography }

    func clearHomographyCache() {
        self.neighborStarHomography = nil
        self.neighborEarthHomography = nil
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
                return ret
            } else if let results = await self.readStarNeighborHomographyForThisFrame() {
                let ret = HomographyResultsCodable(for: frameIndex, with: results.neighborHomography)
                self.neighborStarHomography = ret
                return ret
            }
        case .earth:
            if let ret = neighborEarthHomography {
                return ret
            } else if let results = await self.readEarthNeighborHomographyForThisFrame() {
                let ret = HomographyResultsCodable(for: frameIndex, with: results.neighborHomography)
                self.neighborEarthHomography = ret
                return ret
            }
        default:
            break
        }

        // cached loads failed — calculate homography from feature points

        Log.i("frame \(frameIndex) creating aligned image of type \(type)")

        let config = await configManager.config()

        switch type {
        case .starAligned:
            await frame?.set(state: .starAlignment(.start))
        case .earthAligned:
            if config.tripodHeadWasMoving {
                await frame?.set(state: .earthAlignment(.start))
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
                var keypointFilename = ""

                // Must match what loadOrCreateOCVFeatures wrote for this neighbour,
                // including the detection-scale suffix — see Config.keypointFilename.
                if let name = config.keypointFilename(frameIndex: neighborIndex, ofType: type) {
                    keypointFilename = name
                } else {
                    Log.e("not loading keypoints for type \(type)")
                }

                let keypoints = await keypointCache.load(
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

        Log.d("frame \(frameIndex) doing real alignment for type \(alignmentType)")

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
            // Normally a cheap load of the keypoint file this frame's KeypointOp wrote.
            // But if that op failed — or was never created, as happens when the graph is
            // built for a subrange, since keypoint ops are made only for the range while
            // homography ops are made for every frame — this re-runs full detection. This
            // op reserved nothing (.starHomography/.earthHomography multiply by 0) and
            // holds no limiter slot, so selfGating makes the call take both itself.
            Log.w("frame \(frameIndex) didn't have keypoints in ram for alignment type \(alignmentType), trying to load or create them")
            baseKeypoints = try await loadOrCreateOCVFeatures(of: type, selfGating: true)
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
             // BFMatcher's knnMatch with Lowe's ratio test.  Fully
             // deterministic.  FLANN's KDTree uses random splits in its
             // internal RNG (not exposed via OpenCV) so the same input could
             // return slightly different top-2 matches across runs, which
             // combined with RANSAC variance produced the intermittent
             // bad-homography frames.
             matchMethod: .knnLowes,
             alignmentType: alignmentType,
             maxKeypoints: Int32(config.alignmentMaxKeypoints),
             writeDebugImages: config.alignmentWriteDebugImages,
             handler: { frameIndex,
                        alignmentType,
                        alignmentStep,
                        neighborNumber in

                 Log.d("frame \(frameIndex) got alignment step update \(alignmentStep)")
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

            switch type {
            case .starAligned:
                try await self.write(neighborStarHomography: alignedWarps)
                self.neighborStarHomography = ret
            case .earthAligned:
                try await self.write(neighborEarthHomography: alignedWarps)
                self.neighborEarthHomography = ret
            default:
                break
            }

            return ret
        }

        return nil
    }

    // MARK: - Feature Detection

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
    //
    // `selfGating` is for callers that are NOT already inside a KeypointOp. A KeypointOp
    // holds a KeypointLimiter slot and an AsyncOperation memory reservation for the whole
    // time it runs, so it passes false. The homography fallback holds neither — its op is
    // typed .starHomography/.earthHomography, whose memory multiplier is 0 — so it passes
    // true and this function acquires both itself, but only around the detection, since
    // the common case is a cheap load from the keypoint file.
    func loadOrCreateOCVFeatures(
      of type: FrameViewMode,
      selfGating: Bool = false
    ) async throws -> OCVFeatureSet? {
        var alignmentType: AlignmentType = .sky

        Log.d("frame \(frameIndex) loadOrCreateOCVFeatures")

        let config = await configManager.config()

        switch type {
        case .starAligned:  alignmentType = .sky
        case .earthAligned: alignmentType = .earth
        default:
            throw "unable to loadOrCreateOCVFeatures of type \(type)"
        }

        guard let filename = config.keypointFilename(frameIndex: frameIndex, ofType: type) else {
            throw "unable to loadOrCreateOCVFeatures of type \(type)"
        }

        let fullPath = "\(config.dirForKeypointData)/\(filename)"
        if let features = await keypointCache.load(fromFilename: fullPath) {
            return features
        }

        // Past this point we are going to run SIFT/AKAZE, which measures ~42x the raw
        // frame — 9.9GB at 42MP. A caller that is not a KeypointOp has to take the same
        // limiter slot and reservation a KeypointOp would, or N of these run concurrently
        // with no gating at all. That is a feedback loop, not just an overshoot: memory
        // pressure makes keypoint detection throw, a failed KeypointOp leaves no
        // keypoint file, and the homography phase then re-runs detection for every
        // affected frame at once.
        var heldLimiterSlot = false
        var reservedBytes: UInt64 = 0
        if selfGating {
            Log.w("frame \(frameIndex) running keypoint detection outside a KeypointOp " +
                  "for type \(type) — gating it as one")
            heldLimiterSlot = await frameGraphBuilder.keypointLimiter.acquire()
            if !heldLimiterSlot {
                Log.w("frame \(frameIndex) timed out waiting for a keypoint slot, proceeding")
            }
            reservedBytes = config.rawImageBytes * UInt64(config.keypointMemoryMultiplier)
            if reservedBytes > 0 {
                await MemoryMonitor.shared.reserve(bytes: reservedBytes)
            }
        }
        defer {
            if heldLimiterSlot { frameGraphBuilder.keypointLimiter.release() }
            if reservedBytes > 0 {
                let toRelease = reservedBytes
                Task { await MemoryMonitor.shared.release(bytes: toRelease) }
            }
        }

        Log.i("frame \(frameIndex) creating aligned image of type \(type)")
        switch type {
        case .starAligned:
            await frame?.set(state: .starKeypoints)
        case .earthAligned:
            await frame?.set(state: .earthKeypoints)
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
            horizonMask = try await frame?.loadOrCreateFinalHorizonMask()
            if let horizonMask {
                Log.d("horizon mask \(horizonMask.image.description)")
            }
        }

        Log.d("frame \(frameIndex) finding keypoints of type \(alignmentType)")

        // The gate that used to be here was a call to MemoryMonitor.waitForMemory, which
        // is an empty stub — it never gated anything. Its estimate was also wrong by 4x:
        // the comment claimed ~2.5GB per 42MP frame where the measured figure is 9.9GB.
        // The real reservation is taken by whoever owns this work: the KeypointOp via
        // AsyncOperation, or the selfGating block above.

        let originalFilename = imageAccessor.nameForImage(
          frameIndex: frameIndex, ofType: .original, atSize: .original
        ) ?? "<no name>"
        Log.i("frame \(frameIndex) findFeatures input: " +
              "original=\(originalFrame.description) " +
              "originalFile=\(originalFilename) " +
              "mask=\(horizonMask?.image.description ?? "<none>")")

        if let results = ImageAligner.findFeatures(
             baseImage: originalFrame.mat,
             frameIndex: Int32(frameIndex),
             matchMethod: .knnLowes,
             mask: horizonMask?.image.mat,
             alignmentType: alignmentType,
             maxKeypoints: Int32(config.alignmentMaxKeypoints),
             writeDebugImages: config.alignmentWriteDebugImages,
             groundHorizonExtension: Int32(config.alignmentGroundHorizonExtension),
             baseImageDilateSize: Int32(config.alignmentBaseImageDilateSize),
             baseImageThresholdValue: Int32(config.alignmentBaseImageThresholdValue),
             detectionScale: config.alignmentHalfResolutionKeypoints ? 0.5 : 1.0
           )
        {
            Log.d("frame \(frameIndex) got \(results.keypointCount) keypoints")

            if results.write(toFilename: fullPath) {
                Log.d("frame \(frameIndex) wrote results to \(fullPath)")
            } else {
                Log.w("frame \(frameIndex) failed to write results to \(fullPath)")
            }

            // Pre-populate the keypoint cache so neighbor HomographyOps find
            // this frame's features without a disk round-trip.
            await keypointCache.store(results, forFilename: fullPath)

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

    // MARK: - Aligned Image Creation

    // uses opencv2 for dark ground specific detection logic
    internal func loadOrCreateEarthAlignedImage() async throws -> WarpedImageResult {
        try await loadOrCreateAlignedImage(
          of: .earthAligned,
          withFailedType: .failedEarthAligned
        )
    }

    // uses opencv2 for SIFT fast, accurate image alignment
    internal func loadOrCreateStarAlignedImage() async throws -> WarpedImageResult {
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
    private func loadOrCreateAlignedImage(
      of type: FrameViewMode,
      withFailedType failedType: FrameViewMode? = nil
    ) async throws -> WarpedImageResult {
        var alignmentType: AlignmentType = .sky

        // No gate here either: this was another waitForMemory call, and that function is
        // an empty stub. The reservation for this work belongs to the op that drives it —
        // MergeOp or OutlierOp, at mergeMemoryMultiplier / outlierMemoryMultiplier, which
        // were re-derived to cover exactly this path (it is the dominant cost in both).

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

            let horizonMask = try await frame?.loadOrCreateMergedHorizonMask()
            var results: HomographyResultsCodable? = nil
            switch alignmentType {
            case .earth:
                results = await self.readEarthNeighborHomographyForThisFrame()
                if let results {
                    if let frame {
                        let obs = await frame.getObserver()
                        await obs?.set(earthAlignmentResults: results)
                    }
                }
            case .sky:
                results = await self.readStarNeighborHomographyForThisFrame()
                if let results {
                    if let frame {
                        let obs = await frame.getObserver()
                        await obs?.set(starAlignmentResults: results)
                    }
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
                    let horizonMask = try await frame?.loadOrCreateMergedHorizonMask()
                    var results: HomographyResultsCodable? = nil
                    switch alignmentType {
                    case .earth:
                        results = await self.readEarthNeighborHomographyForThisFrame()
                        if let results {
                            if let frame {
                                let obs = await frame.getObserver()
                                await obs?.set(earthAlignmentResults: results)
                            }
                        }
                    case .sky:
                        results = await self.readStarNeighborHomographyForThisFrame()
                        if let results {
                            if let frame {
                                let obs = await frame.getObserver()
                                await obs?.set(starAlignmentResults: results)
                            }
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
            await frame?.set(state: .creatingStarAlignedFrame)
        case .earthAligned:
            await frame?.set(state: .creatingEarthAlignedFrame)
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
                // No keypoints needed here. This is the warp path: the homographies were
                // computed earlier and are passed in, and ia_align_with_homography reads
                // only filename, maskFilename and frameIndex off each neighbour — it
                // never touches the keypoints field. Loading them was pinning up to
                // numberAlignedNeighborFrames feature sets per frame in the strong,
                // never-evicted keypointCache for nothing. (The homography path, which
                // does need them, loads them separately.)
                let keypoints: OCVFeatureSet? = nil

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

        let pixelThreshold = await frame?.pixelThreshold ?? 0

        if alignmentType == .earth,
           !config.tripodHeadWasMoving
        {
            Log.d("frame \(frameIndex) not aliging earth, just merging")
            // don't try to align if we're combining not moving earth,
            // just median merge them all

            // This is the heaviest merge in the pipeline: base plus
            // numberStaticNeighborFrames sources, all resident at once unless the
            // config lets it stream (~4.3GB vs a few hundred MB at 42MP).
            if let mergedImage = originalFrame.medianMerge(
                 with: self.getStaticNeighborFilenames(),
                 outlierThreshold: pixelThreshold,
                 config: config
               )
            {
                var horizonMask: HorizonMask? = nil
                if config.horizonDetectionEnabled {
                    // use static merged horizons
                    horizonMask = try await frame?.loadOrCreateMergedHorizonMask()
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
                horizonMask = try await frame?.loadOrCreateFinalHorizonMask()
                if let horizonMask {
                    Log.d("horizon mask \(horizonMask.image.description)")
                }
            }

            Log.d("frame \(frameIndex) doing real alignment for type \(alignmentType)")
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
                // Aligning and merging in one call, rather than aligning into an
                // array and merging that, is what keeps this off ten resident
                // frames: the warps never come back here, so each one can be
                // spilled to scratch and released as it is produced. See
                // Config.mergeStreamingThresholdMB for when that engages.
                let result = ImageAligner.alignAndMedianMerge(
                  baseImage: originalFrame.mat,
                  baseFrameIndex: Int32(frameIndex),
                  neighbors: neighbors,
                  homography: homography,
                  outlierThreshold: config.pixelThreshold,
                  includeAll: false,
                  scratchDir: config.tempOutputPath,
                  streamingThresholdBytes:
                    Int64(config.mergeStreamingThresholdMB) * 1024 * 1024
                )

                if let result {
                    Log.d("frame \(frameIndex) merged \(result.warpCount) aligned neighbors")

                    warpedResult = WarpedImageResult(
                      warpedFrame: result.merged,
                      // XXX still unused downstream, and no longer computed: the
                      // warped neighbour masks were being built and dropped here.
                      warpedHorizon: nil
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
            return WarpedImageResult(
              warpedFrame: originalFrame.mat,
              warpedHorizon: nil
            )
        }

        switch type {
        case .starAligned:
            await frame?.set(state: .creatingStarAlignedFrame)
        case .earthAligned:
            await frame?.set(state: .creatingEarthAlignedFrame)
        default:
            break
        }

        if let aligned = warpedResult.warpedFrame,
           let image = PixelatedImage(mat: aligned)
        {
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

    // MARK: - Homography I/O

    public func removeNeighborStarHomography() async throws {
        try? await configManager.homographyDatabase.delete(frameIndex: frameIndex, type: .star)
        deleteHomographyJSONFile(neighborStarHomographyFilename)
    }

    private func write(neighborStarHomography: [AlignmentWarpInfoCodable]) async throws {
        Log.d("frame \(frameIndex) writing \(neighborStarHomography.count) neighborStarHomographies")
        let results = HomographyResultsCodable(for: frameIndex, with: neighborStarHomography)
        try await configManager.homographyDatabase.write(frameIndex: frameIndex, type: .star, results: results)
        if let frame {
            Log.d("frame \(frameIndex) notifying observer of star alignment results")
            let obs = await frame.getObserver()
            await obs?.set(starAlignmentResults: results)
        }
    }

    private func write(neighborEarthHomography: [AlignmentWarpInfoCodable]) async throws {
        let results = HomographyResultsCodable(for: frameIndex, with: neighborEarthHomography)
        try await configManager.homographyDatabase.write(frameIndex: frameIndex, type: .earth, results: results)
        if let frame {
            let obs = await frame.getObserver()
            await obs?.set(earthAlignmentResults: results)
        }
    }

    public func readStarNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await readHomographyResults(type: .star)
    }

    public func readEarthNeighborHomographyForThisFrame() async -> HomographyResultsCodable? {
        await readHomographyResults(type: .earth)
    }

    private func readHomographyResults(type: HomographyDatabase.HomographyType) async -> HomographyResultsCodable? {
        let db = configManager.homographyDatabase
        if let result = try? await db.read(frameIndex: frameIndex, type: type) {
            return result
        }
        // Migration path: read legacy JSON file, write to DB, delete the file
        let filename = type == .star ? neighborStarHomographyFilename : neighborEarthHomographyFilename
        guard let result = await readHomographyFromJSONFile(filename) else { return nil }
        try? await db.write(frameIndex: frameIndex, type: type, results: result)
        deleteHomographyJSONFile(filename)
        return result
    }

    private func readHomographyFromJSONFile(_ filename: String) async -> HomographyResultsCodable? {
        guard let dirname = imageAccessor.dirForImage(ofType: .starAligned, atSize: .original) else {
            return nil
        }
        do {
            let fullPath = "\(dirname)/\(frameIndex)/\(filename)"
            let url = NSURL(fileURLWithPath: fullPath, isDirectory: false) as URL
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            return try JSONDecoder().decode(HomographyResultsCodable.self, from: data)
        } catch {
            return nil
        }
    }

    private func deleteHomographyJSONFile(_ filename: String) {
        guard let dirname = imageAccessor.dirForImage(ofType: .starAligned, atSize: .original) else { return }
        try? FileManager.default.removeItem(atPath: "\(dirname)/\(frameIndex)/\(filename)")
    }

    public func removeNumberOfAlignedImagesForThisFrameFile() async throws {
        try? await configManager.homographyDatabase.deleteAll(frameIndex: frameIndex)
        // Also clean up any legacy JSON files from pre-DB runs
        if let dirname = imageAccessor.dirForImage(ofType: .starAligned, atSize: .original) {
            try? removeFiles(withSuffix: ".json", in: "\(dirname)/\(frameIndex)")
        }
    }

    // MARK: - State forwarding (synchronous hop to the owning frame's executor)

    // Called from within the homography handler closure which is @Sendable and
    // non-isolated, so we can't directly await frame — schedule a fire-and-forget Task.
    nonisolated func set(state: FrameProcessingState) {
        Task {
            await frame?.set(state: state)
        }
    }
}
