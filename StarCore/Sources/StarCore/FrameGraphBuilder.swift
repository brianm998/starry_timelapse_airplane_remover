import Foundation
import logging

public let frameGraphBuilder = FrameGraphBuilder()

public enum OperationType: String, CaseIterable, Sendable {
    case preview
    case horizon
    case mergedHorizon
    case starKeypoints = "star kp"
    case earthKeypoints = "earth kp"
    case starHomography = "star align"
    case earthHomography = "earth align"
    case alignmentValidation
    case outliers
    case merge
}

extension OperationType {
    /// Multiplier applied to `Config.workingFrameBytes` to estimate how much memory this
    /// operation type needs.
    ///
    /// Every non-zero value here is a FALLBACK: FrameGraphBuilder passes the
    /// corresponding `Config` value explicitly at each construction site, so these only
    /// apply to an op built without one. They are kept at or above the config defaults so
    /// that path can never be quietly cheaper than the gated one.
    ///
    /// 0 means the op works on small data — homographies, validation — and needs no
    /// reservation. Note the homography ops can still run keypoint detection on a cache
    /// miss; that path gates itself rather than relying on this (see
    /// `FrameAlignmentProcessor.loadOrCreateOCVFeatures(of:selfGating:)`).
    ///
    /// The per-case notes live with the config properties these mirror, since that is
    /// where the measurements are recorded.
    var memoryMultiplier: UInt64 {
        switch self {
        case .preview:             return 2
        // Fallbacks only — FrameGraphBuilder passes config.effectiveHorizonMemoryMultiplier()
        // explicitly.  Not 7, the config default: that default is only honest at 24MP and
        // up, because a horizon op's cost is mostly fixed rather than per-pixel and the
        // config applies a byte floor (horizonReservationFloorMB) to cover the small end.
        // A fallback cannot see the frame size, so it cannot apply a floor, and takes the
        // worst measured ratio instead — 12.3x, at 6MP, rounded up.
        case .horizon:             return 13
        case .mergedHorizon:       return 13
        // Fallback only — FrameGraphBuilder always passes effectiveKeypointMemoryMultiplier()
        // explicitly when building KeypointOps.  Kept in step with that default (42,
        // measured) so this cannot become a stale second opinion.
        case .starKeypoints:       return 42
        case .earthKeypoints:      return 42
        case .starHomography:      return 0
        case .earthHomography:     return 0
        case .alignmentValidation: return 0
        // Fallbacks only — FrameGraphBuilder passes config.effective*MemoryMultiplier
        // explicitly, with the frame's actual neighbour counts.  These are the config
        // defaults (9 and 6) plus the largest residentBuildExtraMultiplier those defaults
        // can produce (numberStaticNeighborFrames - 1 = 15): a fallback can see neither
        // the frame size nor the neighbour counts, so it assumes the worst of both — no
        // merge inside the op streams, and every neighbour is present.
        case .outliers:            return 24
        case .merge:               return 21
        }
    }
}

public enum OperationState: String, CaseIterable, Sendable {
    case queued
    case running
    case done
}

// uses OperationQueues to allow processing with dependencies and configurable max processing
public final actor FrameGraphBuilder {

    // MARK: Queues (user adjustable)
    let queue = OperationQueue()

    // Dedicated queue for preview/thumbnail ops so they are never blocked
    // behind heavy frame-processing operations that fill the main queue slots.
    let previewQueue = OperationQueue()

    let keypointLimiter = KeypointLimiter(max: max(1, ProcessInfo.processInfo.processorCount / 2))

    public init() {
        queue.name = "operations"
        previewQueue.name = "previews"
        previewQueue.maxConcurrentOperationCount = 3
    }

    var configManager: ConfigManager? = nil

    public func set(configManager: ConfigManager) async {
        self.configManager = configManager
        self.update(from: await configManager.config())
        await configManager.onUpdate { [weak self] config in
            Task {
                await self?.update(from: config)
            }
        }
    }

    public func update(from config: Config) {
        queue.maxConcurrentOperationCount = config.numberOfFramesToProcessConcurrently
        applyKeypointLimit(from: config, context: "configure")

        Task {
            await MemoryMonitor.shared.configure(budgetFraction: config.maxMatMemoryFraction)
            await keypointCache.configure(maxBytes: config.keypointCacheMaxMB * 1024 * 1024)
        }
    }

    /// Apply the keypoint concurrency cap, and say which term decided it.
    ///
    /// Called both when the config is set and again when the graph is built, since the
    /// config can change in between. One implementation for both, so the two cannot
    /// disagree — they previously computed the same thing twice with slightly different
    /// arithmetic.
    private func applyKeypointLimit(from config: Config, context: String) {
        let kc = config.keypointConcurrency(
          physicalMemory: UInt64(ProcessInfo.processInfo.physicalMemory)
        )
        keypointLimiter.set(max: kc.limit)

        guard let budgetLimit = kc.budgetLimit else {
            // Whoever built this config never called Config.set(imageInfo:).  Everything
            // downstream degrades silently: rawImageBytes is 0, so every op's
            // estimatedMemoryBytes is 0 and AsyncOperation skips reserve() altogether,
            // and the keypoint limiter falls back to the frame concurrency count.  On
            // high-resolution sequences that means N concurrent SIFT ops with no gating
            // whatsoever.  Loud, because it is invisible otherwise.
            Log.e("MEMORY GATING DISABLED [\(context)]: config has no image dimensions " +
                  "(\(config.imageWidth)×\(config.imageHeight)×\(config.imageBytesPerPixel)B). " +
                  "Call config.set(imageInfo:) before building the frame graph. " +
                  "Every operation will reserve 0 bytes and the keypoint limiter is " +
                  "capped only by numberOfFramesToProcessConcurrently (\(kc.limit)).")
            // Also a user-facing warning, not only a log line: this is the exact defect
            // that shipped in 0.11.1 and got a user's cli killed on a high-resolution
            // sequence. A run in this state has no memory gating at all, so if it is going
            // to die it will, and the user should hear about it before it does.
            Task {
                await StarWarnings.shared.post(StarWarning(
                  kind: .memoryGatingDisabled,
                  severity: .critical,
                  message: localized("warning.memory_gating_disabled.message"),
                  suggestion: localized("warning.memory_gating_disabled.suggestion")
                ))
            }
            return
        }

        let explicit = config.maxConcurrentKeypointOps > 0
            ? ", explicit cap \(config.maxConcurrentKeypointOps)"
            : ""
        Log.i("KeypointLimiter[\(context)]: \(kc.limit) concurrent keypoint ops — " +
              "budget fits \(budgetLimit) " +
              "(image \(config.imageWidth)×\(config.imageHeight)×\(config.imageBytesPerPixel)B, " +
              "working frame \(config.workingFrameBytes/(1024*1024))MB × \(config.effectiveKeypointMemoryMultiplier()) " +
              "(divisor \(config.quantizedKeypointDivisor)) = " +
              "\(kc.bytesPerOp/(1024*1024))MB/op of \(kc.budget/(1024*1024))MB budget), " +
              "frames cap \(config.numberOfFramesToProcessConcurrently)\(explicit) " +
              "→ bound by \(kc.binding)")
    }

    public func add(operation: Operation) {
        if let asyncOp = operation as? AsyncOperation, asyncOp.type == .preview {
            previewQueue.addOperation(operation)
        } else {
            queue.addOperation(operation)
        }
    }
    
    /// Decide which cached stages this run may no longer reuse, and undo the work that
    /// depended on them.
    ///
    /// The skip predicates ask only whether an artifact exists, which is as strong as the
    /// loads they replaced but means a settings change had no effect on an
    /// already-processed sequence: raising `alignmentMaxKeypoints` left every frame with
    /// its old feature file.  `ArtifactInputs` closes that by recording what each stage
    /// was built with; anything that differs makes that stage — and everything downstream
    /// of it — ineligible for reuse.
    ///
    /// A stale artifact is deleted, not merely left unused.
    ///
    /// Declining to reuse it here is not enough, and that mistake is worth recording: the
    /// loaders reuse whatever is on disk independently of this. `loadOrCreateOCVFeatures`
    /// returns the file if it can parse it, and `KeypointOp.hasWorkToDo()` skips on the
    /// file existing — so a stale feature file that is left in place gets loaded by the
    /// homography stage anyway, and the settings change still does nothing. Measured that
    /// exact outcome before deleting: the keypoint files came out byte-identical after
    /// dropping `alignmentMaxKeypoints` from 2000 to 600.
    ///
    /// Deleting is also what makes an interrupted run consistent rather than mixed. Every
    /// artifact is a regenerable cache under `star_temp_*`, and the frames whose rebuild
    /// this run does not reach simply have none — so the next run builds them from the
    /// current settings instead of finding old ones and trusting them.
    ///
    /// Confined to the frames this run will actually rebuild. Deleting the whole
    /// sequence's artifacts when asked to process a hundred frames of it would throw away
    /// work this run has no intention of redoing.
    ///
    /// The alignment products go too, and they are the reason this warns the user rather
    /// than only logging: a stored homography was fitted to the old keypoints and
    /// `homography.db` is keyed by frame index alone, so there is no version of it to
    /// keep. `invalidateStarAlignmentIfExists` drops it along with the images derived from
    /// it, which includes rendered output the user can see.
    private func invalidateStaleArtifacts(
      frames: [FrameAirplaneRemover],
      range: FrameGraphRange,
      framesByIndex: [Int: FrameAirplaneRemover],
      config: Config
    ) async {
        let current = ArtifactInputs.current(from: config)
        let stored = ArtifactInputs.load(fromTempOutputPath: config.tempOutputPath)
        let stale = current.staleStages(comparedTo: stored)

        guard !stale.isEmpty, let stored else {
            if stored == nil {
                // Every sequence processed before this existed is in this state.  Adopt
                // the current settings rather than assuming the worst — see
                // `staleStages(comparedTo:)`.
                Log.i("no artifact input record in \(config.tempOutputPath), recording " +
                      "this run's settings without invalidating anything")
            }
            persistArtifactInputs(current,
                                  toTempOutputPath: config.tempOutputPath,
                                  range: range,
                                  frames: frames)
            return
        }

        // Which settings, not just which stages: a run about to discard alignment should
        // say what it is doing that for.
        let differences = current.differences(from: stored)
        for stage in ArtifactStage.allCases {
            guard let changes = differences[stage] else { continue }
            // Truncated, because a mode flag flipping brings a dozen settings into the
            // record with it and the whole list buries the one that matters.
            // `differences` orders the settings that actually moved first, so the head of
            // the list is the informative part.
            let shown = 4
            let described = changes.count > shown
              ? changes.prefix(shown).joined(separator: ", ")
                  + ", and \(changes.count - shown) more"
              : changes.joined(separator: ", ")
            Log.i("\(stage.logDescription) settings changed: \(described)")
        }
        let described = ArtifactStage.allCases
          .filter { stale.contains($0) }
          .map { $0.logDescription }
          .joined(separator: ", ")
        Log.i("rebuilding \(described) — stages downstream of a change are stale too, " +
              "since their inputs came from the old settings")

        // Same ranges the reuse survey uses, so a deleted artifact is always one this run
        // goes on to rebuild.
        if stale.contains(.horizon) {
            var deleted = 0
            for frameIndex in range.horizon {
                guard let frame = framesByIndex[frameIndex] else { continue }
                guard frame.horizonMaskExistsOnDisk() else { continue }
                frame.imageAccessor.deleteImages(frameIndex: frameIndex,
                                                 ofTypes: [.horizon],
                                                 atSizes: [.original, .preview])
                deleted += 1
            }
            Log.i("deleted \(deleted) stale horizon mask(s)")
        }
        if stale.contains(.mergedHorizon) {
            var deleted = 0
            for frameIndex in range.keypoint {
                guard let frame = framesByIndex[frameIndex] else { continue }
                guard frame.mergedHorizonMaskExistsOnDisk() else { continue }
                frame.imageAccessor.deleteImages(frameIndex: frameIndex,
                                                 ofTypes: [.mergedHorizon],
                                                 atSizes: [.original, .preview])
                deleted += 1
            }
            Log.i("deleted \(deleted) stale merged horizon mask(s)")
        }
        if stale.contains(.keypoints) {
            // Both alignment types, whether or not this run uses earth alignment: an
            // earth feature file left behind is just as stale as the sky one beside it.
            var deleted = 0
            for frameIndex in range.keypoint {
                for type in [FrameViewMode.starAligned, .earthAligned] {
                    guard let path = config.keypointPath(frameIndex: frameIndex,
                                                         ofType: type),
                          FileManager.default.fileExists(atPath: path)
                    else { continue }
                    do {
                        try FileManager.default.removeItem(atPath: path)
                        deleted += 1
                    } catch {
                        // Not fatal, but it does mean this frame will reuse a stale file,
                        // so it is worth more than a debug line.
                        Log.w("could not delete stale \(path): \(error)")
                    }
                }
            }
            // The in-memory cache is keyed by that same path, so a hit there would serve
            // the file this just deleted for the rest of the process.
            await keypointCache.clear()
            Log.i("deleted \(deleted) stale keypoint file(s) and cleared the keypoint cache")

            var invalidated = 0
            for frame in frames where range.output.contains(frame.frameIndex) {
                if (try? await frame.invalidateStarAlignmentIfExists()) == true {
                    invalidated += 1
                }
            }
            if invalidated > 0 {
                Log.i("discarded the stored homography and the images derived from it " +
                      "for \(invalidated) frame(s); they will be re-aligned and re-rendered")
                await StarWarnings.shared.post(StarWarning(
                  kind: .artifactsInvalidated,
                  severity: .warning,
                  message: localized("warning.artifacts_invalidated.message",
                                     invalidated),
                  suggestion: localized("warning.artifacts_invalidated.suggestion")
                ))
            }
        }

        persistArtifactInputs(current,
                              toTempOutputPath: config.tempOutputPath,
                              range: range,
                              frames: frames)
    }

    /// Record this run's settings — but only when it is going to cover the whole
    /// sequence.
    ///
    /// The record has no per-frame granularity, so writing it after a partial run would
    /// claim the new settings for frames this run never touched, and their stale
    /// artifacts would be reused forever after.  Leaving it means the next run sees the
    /// same change and rebuilds the rest; the cost is that the frames this run already
    /// rebuilt get rebuilt again, which is the safe direction to be wrong in.
    private func persistArtifactInputs(
      _ inputs: ArtifactInputs,
      toTempOutputPath tempOutputPath: String,
      range: FrameGraphRange,
      frames: [FrameAirplaneRemover]
    ) {
        guard range.output.count == frames.count else {
            Log.i("processing \(range.output.count) of \(frames.count) frames, so not " +
                  "recording these settings yet — a partial run would claim them for " +
                  "frames it never rebuilt")
            return
        }
        do {
            try inputs.save(toTempOutputPath: tempOutputPath)
        } catch {
            // Not fatal: the cost is that the next run re-detects the same change and
            // rebuilds again, which is wasteful rather than wrong.
            Log.w("could not record artifact input settings: \(error)")
        }
    }

    public func build(
      frames: [FrameAirplaneRemover],
      startIndex: Int = 0,
      endIndex: Int? = nil,      // will be last index of frames
      closure: @escaping ([String]) -> Void,
      errorClosure: @escaping @Sendable (String) -> Void
    ) async {
        guard let configManager else {
            errorClosure("cannot build without config manager")
            closure(["cannot build without config manager"])
            return
        }

        let errors = ArrayActor<String>([])

        let config = await configManager.config()

        // The unit each op multiplies by its memoryMultiplier. Deliberately the working
        // frame rather than the source frame: the multipliers were derived at 16-bit, and
        // the work they describe is per-pixel, so an 8-bit source must not halve them.
        let rawImageBytes = config.workingFrameBytes

        // Recalculate now that the config is final — dimensions may have been set, or
        // any of the three limiting terms changed, since update(from:) ran.
        applyKeypointLimit(from: config, context: "build")

        let hasHorizon = config.horizonDetectionEnabled
        // Skip per-frame detection and merge when the user has painted a global
        // reference horizon for a static sequence — the reference.tiff will be
        // loaded directly by each operation that needs the horizon mask.
        let hasStaticReferenceHorizon = config.hasStaticReferenceHorizon && !config.tripodHeadWasMoving
        let processEarth = config.allowEarthAlignment &&
          config.tripodHeadWasMoving // keypoints not used when stationary

        var mergedHorizonOps: [Int: Operation] = [:]
        // The static case runs exactly one horizon merge for the whole sequence, so it
        // is held on its own rather than in the per-frame map above.
        var staticMergedHorizonOp: Operation? = nil
        var homographyOps: [Operation] = []
        var mergeOps: [Operation] = []

        var skyKeypointOps: [Int: Operation] = [:]
        var earthKeypointOps: [Int: Operation] = [:]

        var outlierOps: [Int: OutlierOp] = [:]

        // Look up frames by their actual `frameIndex`, never by array index.
        // The caller is responsible for passing the full sequence, but if
        // anything ever passes a subset or a scrambled order this lookup
        // still does the right thing (or returns nil) instead of silently
        // pulling the wrong frame from a coincidental array slot.
        let framesByIndex: [Int: FrameAirplaneRemover] = Dictionary(
          uniqueKeysWithValues: frames.map { ($0.frameIndex, $0) }
        )

        // Each frame's neighbour structure, gathered up front: it decides both which
        // frames the alignment stages have to reach outside the requested range (see
        // FrameGraphRange) and which keypoint ops each homography op depends on, and
        // those two must agree or a homography waits on an op that was never built.
        var alignmentNeighbours: [Int: [Int]] = [:]
        var horizonMergeNeighbours: [Int: [Int]] = [:]
        for frame in frames {
            alignmentNeighbours[frame.frameIndex] = await frame.getAlignmentFrameIndices()
            // Only a moving sequence merges each frame's horizon from a named set of
            // neighbours.  A static one has a single merge op that votes over the whole
            // sequence and loads any mask it was not handed from disk, so there is
            // nothing for the horizon stage to widen to.
            if config.tripodHeadWasMoving {
                horizonMergeNeighbours[frame.frameIndex] = await frame.getHorizonMergeIndices()
            }
        }

        // Which frames each stage runs on.  Only `range.output` gets outlier and merge
        // ops — those are what write a frame's output image — while the alignment
        // stages reach past the range for the neighbours those frames align against.
        let range = FrameGraphRange(
          sequenceIndices: frames.map(\.frameIndex),
          startIndex: startIndex,
          endIndex: endIndex,
          alignmentNeighbours: alignmentNeighbours,
          horizonMergeNeighbours: horizonMergeNeighbours
        )

        guard !range.isEmpty,
              let firstOutputIndex = range.output.first,
              let lastOutputIndex = range.output.last
        else {
            // An empty sequence, a startIndex past the end of it, or an endIndex below
            // startIndex.  Reported rather than ignored, and reported through both
            // closures so a caller waiting on the completion one does not hang.
            let requested = endIndex.map { "\(startIndex) to \($0)" } ?? "\(startIndex) to end"
            let sequenceIndices = frames.map(\.frameIndex)
            let held = if let low = sequenceIndices.min(), let high = sequenceIndices.max() {
                "\(low) to \(high)"
            } else {
                "none"
            }
            let msg = "no frames to process: requested frameIndex \(requested), " +
              "sequence holds frameIndex \(held)"
            Log.e(msg)
            errorClosure(msg)
            closure([msg])
            return
        }

        // The largest frame index in the sequence, not in the range: the horizon
        // accumulator is indexed by frame index over the whole sequence, and neighbour
        // lookups clamp against the sequence, not against what we were asked to write.
        let maxFrameIndex = frames.map(\.frameIndex).max() ?? lastOutputIndex

        // The frames we will write output for, in frame-index order.
        let outputFrames = range.output.compactMap { framesByIndex[$0] }

        var allOps: [Operation] = []

        Log.i("processing frameIndex \(firstOutputIndex) to \(lastOutputIndex): " +
              "\(range.output.count) frame(s) to write, \(range.keypoint.count) to align, " +
              "\(range.horizon.count) to detect a horizon for")

        // ---- What is already on disk -----------------------------------------------
        //
        // Asked once, here, instead of being discovered by each op as it runs.  Every
        // stage below used to establish "this frame is already done" only by fully
        // reading the artifact it would have written: a 45ms YAML parse per feature set,
        // a ~120ms full-res decode plus row-by-row bounds scan per horizon mask, and the
        // same again per merged mask.  On an unchanged 1312-frame 6000×4000 sequence
        // that came to ~370s of CPU and 3.1GB of reads spent concluding there was
        // nothing to do — and it was paid *inside* the memory gate, since an op reserves
        // before it executes, so a KeypointOp held 7.2GB while parsing a file it did not
        // need.  The reservation, not the work, was setting the pace of a re-run.
        //
        // Answering the same question by `stat` costs ~6us per frame per artifact: 22ms
        // for that whole sequence.  Frames whose artifact is present get no op at all,
        // and `AsyncOperation.hasWorkToDo()` is the backstop for the ops that are built.
        //
        // Before the survey, and deliberately by deleting rather than by handing this a
        // list to ignore: a file whose settings have changed is removed, so every
        // existence check below — and every existence check in the loaders and in
        // `hasWorkToDo()`, which this cannot reach — agrees without being told.
        await invalidateStaleArtifacts(
          frames: frames,
          range: range,
          framesByIndex: framesByIndex,
          config: config
        )

        var haveHorizon:        Set<Int> = []
        var haveMergedHorizon:  Set<Int> = []
        var haveSkyKeypoints:   Set<Int> = []
        var haveEarthKeypoints: Set<Int> = []

        for frameIndex in range.horizon {
            guard let frame = framesByIndex[frameIndex] else { continue }
            if frame.horizonMaskExistsOnDisk() { haveHorizon.insert(frameIndex) }
        }
        for frameIndex in range.keypoint {
            guard let frame = framesByIndex[frameIndex] else { continue }
            if frame.mergedHorizonMaskExistsOnDisk() {
                haveMergedHorizon.insert(frameIndex)
            }
            if frame.keypointsExistOnDisk(ofType: .starAligned, config: config) {
                haveSkyKeypoints.insert(frameIndex)
            }
            if processEarth,
               frame.keypointsExistOnDisk(ofType: .earthAligned, config: config)
            {
                haveEarthKeypoints.insert(frameIndex)
            }
        }

        // Said up front and at info level on purpose.  A re-run of an unchanged sequence
        // used to spend many minutes looking busy before it could report that there was
        // nothing to do; the survey above already knows, so it says so now.
        Log.i("already on disk: " +
              "\(haveHorizon.count)/\(range.horizon.count) horizon masks, " +
              "\(haveMergedHorizon.count)/\(range.keypoint.count) merged horizons, " +
              "\(haveSkyKeypoints.count)/\(range.keypoint.count) sky keypoint sets" +
              (processEarth
                 ? ", \(haveEarthKeypoints.count)/\(range.keypoint.count) earth keypoint sets"
                 : ""))

        // Where the one static horizon merge would run, and whether it has anything to
        // do.  Resolved here because the accumulator below is only worth building if
        // that merge is going to consume it.
        //
        // Which frame anchors it does not matter: the mask is a vote over the whole
        // sequence and gets hard-linked to every frame in it.
        let staticMergeAnchor: FrameAirplaneRemover? = config.tripodHeadWasMoving
          ? nil
          : range.keypoint.first.flatMap { framesByIndex[$0] }
        let staticMergeNeeded = staticMergeAnchor
          .map { !haveMergedHorizon.contains($0.frameIndex) } ?? false

        // For static sequences without a reference horizon, create a shared accumulator
        // so that HorizonDetectionOps feed their results in as they complete, avoiding
        // a full disk reload of all masks during the later HorizonMergeOp.
        //
        // Only when that merge will actually run.  With the merged mask already on disk
        // the merge returns the file and never reads the accumulator, so registering one
        // commits every frame in the sequence to a full-res decode whose result is then
        // dropped on the floor — which was the single largest cost of a re-run.
        let horizonAccumulatorInUse = hasHorizon
          && !hasStaticReferenceHorizon
          && !config.tripodHeadWasMoving
          && staticMergeNeeded

        if horizonAccumulatorInUse {
            // HorizonAccumulator sizes its internal table by frameCount and
            // indexes it directly by frameIndex, so it must cover up through
            // the largest frame index in the sequence.
            let accumulator = HorizonAccumulator(frameCount: maxFrameIndex + 1)
            // Registered on exactly the frames that will run a HorizonDetectionOp, so
            // every mask this graph computes is folded in as it completes and only the
            // rest are reloaded from disk at finalize time.
            for frameIndex in range.horizon {
                if let frame = framesByIndex[frameIndex] {
                    await frame.setHorizonAccumulator(accumulator)
                }
            }
            Log.i("created HorizonAccumulator for \(range.horizon.count) frames")
        }

        // First assemble initial horizon operations,
        // with no dependencies upon any other operations.
        // Skipped when the user has painted a global reference for a static sequence.
        let horizonOps = await withTaskGroup(
          of: HorizonDetectionOp?.self
        ) { taskGroup in
            for frameIndex in range.horizon {
                guard let frame = framesByIndex[frameIndex] else { continue }
                // Mask already on disk and nothing needs it in memory.  When the
                // accumulator is in use the decode *is* the work, and doing it here in
                // parallel is the whole point of having one — so those still get an op.
                if haveHorizon.contains(frameIndex), !horizonAccumulatorInUse { continue }
                taskGroup.addTask() {
                    // 1. Horizon
                    if hasHorizon && !hasStaticReferenceHorizon {
                        let horizonOp = HorizonDetectionOp(
                          frame: frame,
                          rawImageBytes: rawImageBytes,
                          memoryMultiplier: UInt64(config.effectiveHorizonMemoryMultiplier()),
                          feedsAccumulator: horizonAccumulatorInUse
                        ) { errorString in
                            Task { await errors.append(errorString) }
                            errorClosure(errorString)
                        }
                        horizonOp.queuePriority = .low
                        horizonOp.qualityOfService = .userInteractive
                        return horizonOp
                    } else {
                        return nil
                    }
                }
            }

            var ret: [Int: Operation] = [:]
            for await op in taskGroup {
                if let op { ret[op.frame.frameIndex] = op }
            }
            return ret
        }

        allOps.append(
          contentsOf: horizonOps
            .sorted { $0.key < $1.key }
            .map { $0.value }
        )

        // next assemble merged horizons, which each depend upon an array of
        // original horizon operations from above.
        // Skipped when the user has painted a global reference for a static sequence.
        if hasHorizon && !hasStaticReferenceHorizon {
            if config.tripodHeadWasMoving {
                /*
                 Moving tripods have separate HorizonMergsOps for each frame,
                 gathering the masks of a set of neighbors.
                 */
                mergedHorizonOps = await withTaskGroup(
                  of: HorizonMergeOp.self
                ) { taskGroup in
                    // Every frame we detect keypoints for needs a merged mask to mask
                    // them with, which is wider than the frames we write output for.
                    for frameIndex in range.keypoint {
                        guard let frame = framesByIndex[frameIndex] else { continue }
                        // The merged file is this op's only durable output, so with it
                        // already there the op is a decode and a bounds scan for nothing.
                        if haveMergedHorizon.contains(frameIndex) { continue }
                        taskGroup.addTask {
                            let horizonOp = HorizonMergeOp(
                              frame: frame,
                              rawImageBytes: rawImageBytes,
                              memoryMultiplier: UInt64(config.effectiveHorizonMemoryMultiplier())
                            ) { errorString in
                                Task { await errors.append(errorString) }
                                errorClosure(errorString)
                            }
                            horizonOp.queuePriority = .normal
                            horizonOp.qualityOfService = .userInteractive
                            return horizonOp
                        }
                    }

                    var ret: [Int: HorizonMergeOp] = [:]
                    for await op in taskGroup {
                        await op.addDependencies(from: horizonOps)
                        ret[op.frame.frameIndex] = op
                    }
                    return ret
                }
                allOps.append(
                  contentsOf: mergedHorizonOps
                    .sorted { $0.key < $1.key }
                    .map { $0.value }
                )
            } else {
                /*
                 for static tripod:
                 execute just one horizon merge op that
                 depends upon all other horizon operations
                 */
                // Anchored on the first frame that needs a merged mask rather than on
                // `startIndex`, which the caller need not have passed us a frame for —
                // resolved as `staticMergeAnchor` above, since whether this op is needed
                // decides whether there is an accumulator to feed it.
                //
                // `staticMergeNeeded` is false only when the anchor's merged mask is
                // already on disk, and the static path hard-links that one file to every
                // frame in the sequence — so one frame having it means they all do.
                if !staticMergeNeeded {
                    // Nothing to build.  The keypoint ops below simply get no merged
                    // horizon dependency and read the mask from disk if they need it.
                    Log.i("static merged horizon already on disk, not building a merge op")
                } else if let frame = staticMergeAnchor {
                    let horizonOp = HorizonMergeOp(
                      frame: frame,
                      rawImageBytes: rawImageBytes,
                      memoryMultiplier: UInt64(config.effectiveHorizonMemoryMultiplier())
                    ) { errorString in
                        Task { await errors.append(errorString) }
                        errorClosure(errorString)
                    }
                    horizonOp.queuePriority = .normal
                    horizonOp.qualityOfService = .userInteractive
                    staticMergedHorizonOp = horizonOp
                    for op in horizonOps.values {
                        horizonOp.addDependency(op)
                    }
                    allOps.append(horizonOp)
                } else {
                    let msg = "no frame to anchor the static HorizonMergeOp on"
                    Log.e(msg)
                    errorClosure(msg)
                    closure([msg])
                    return
                }
            }
        }

        skyKeypointOps = await withTaskGroup(
          of: KeypointOp.self
        ) { taskGroup in
            // Keypoints depend upon the merged horizon mask for their index.
            // Wider than the frames we write output for: each of those aligns against
            // neighbours whose keypoints have to exist for its homography to be built
            // here, instead of being detected inline by the homography op outside the
            // KeypointLimiter's memory gate.
            for frameIndex in range.keypoint {
                guard let frame = framesByIndex[frameIndex] else { continue }
                // Feature set already on disk.  Skipping leaves it out of RAM, which
                // costs nothing: the homography stage reads a stored homography without
                // needing keypoints, and where it does need them it loads the file under
                // a gate of its own.
                if haveSkyKeypoints.contains(frameIndex) { continue }
                taskGroup.addTask {
                    // 2. Keypoints (always sky)
                    let skyKP = KeypointOp(
                      forStars: true,
                      frame: frame,
                      mode: .starAligned,
                      limiter: self.keypointLimiter,
                      rawImageBytes: rawImageBytes,
                      memoryMultiplier: UInt64(config.effectiveKeypointMemoryMultiplier()),
                      keypointPath: config.keypointPath(frameIndex: frameIndex,
                                                        ofType: .starAligned)
                    ) { errorString in
                        Task { await errors.append(errorString) }
                        errorClosure(errorString)
                    }

                    skyKP.queuePriority = .high
                    skyKP.qualityOfService = .userInteractive
                    return skyKP
                }
            }

            var ret: [Int: KeypointOp] = [:]
            for await op in taskGroup {
                //await op.addDependencies(from: horizonOps)

                if hasHorizon {
                    if config.tripodHeadWasMoving {
                        if let horizonOp = mergedHorizonOps[op.frame.frameIndex] {
                            op.addDependency(horizonOp)
                        }
                    } else {
                        // static video, single merged horizon op
                        if let horizonOp = staticMergedHorizonOp {
                            op.addDependency(horizonOp)
                        }
                    }
                }
                
                ret[op.frame.frameIndex] = op
            }
            return ret
        }
        allOps.append(
          contentsOf: skyKeypointOps
            .sorted { $0.key < $1.key }
            .map { $0.value }
        )
            
        if hasHorizon && processEarth {
            earthKeypointOps = await withTaskGroup(
              of: KeypointOp.self
            ) { taskGroup in
                // Keypoints depend upon the merged horizon mask for their index
                for frameIndex in range.keypoint {
                    guard let frame = framesByIndex[frameIndex] else { continue }
                    if haveEarthKeypoints.contains(frameIndex) { continue }
                    taskGroup.addTask {
                        // 2b. Earth keypoints (optional)
                        let kp = KeypointOp(
                          forStars: false,
                          frame: frame,
                          mode: .earthAligned,
                          limiter: self.keypointLimiter,
                          rawImageBytes: rawImageBytes,
                          memoryMultiplier: UInt64(config.effectiveKeypointMemoryMultiplier()),
                          keypointPath: config.keypointPath(frameIndex: frameIndex,
                                                            ofType: .earthAligned)
                        ) { errorString in
                            Task { await errors.append(errorString) }
                            errorClosure(errorString)
                        }
                        kp.queuePriority = .high
                        kp.qualityOfService = .userInteractive
                        return kp
                    }
                }
                var ret: [Int: KeypointOp] = [:]
                for await op in taskGroup {
                    if let dep = skyKeypointOps[op.frame.frameIndex] {
                        op.addDependency(dep)
                    }
                    ret[op.frame.frameIndex] = op
                }
                return ret
            }
            allOps.append(
              contentsOf: earthKeypointOps
                .sorted { $0.key < $1.key }
                .map { $0.value }
            )
        }

        // next assemble homography operations that depend upon the keyframes from above
        // these depend upon an array of self + neighbor keypoints
        //
        // Only for the frames we write output for: a merge warps its neighbours onto
        // itself with its own homography, so a frame outside the range needs none.
        for frame in outputFrames {
            // 3. Homographies
            let skyH = HomographyOp(
              forStars: true,
              frame: frame,
              mode: .starAligned,
              rawImageBytes: rawImageBytes
            ) { errorString in
                Task { await errors.append(errorString) }
                errorClosure(errorString)
            }
            skyH.queuePriority = .veryHigh
            skyH.qualityOfService = .userInteractive
            
            // Depends on this frame's sky keypoints
            if let selfKP = skyKeypointOps[frame.frameIndex] {
                skyH.addDependency(selfKP)
            }

            // Depends on neighbors' sky keypoints.  Read from the same map that decided
            // `range.keypoint`, so every neighbour named here has an op above.
            let neighbourIndices = alignmentNeighbours[frame.frameIndex] ?? []

            for neighborIndex in neighbourIndices {
                if let neighborKP = skyKeypointOps[neighborIndex] {
                    skyH.addDependency(neighborKP)
                }
            }

            allOps.append(skyH)
            homographyOps.append(skyH)

            // ---- Earth-aligned homography (optional) ----
            if hasHorizon && processEarth {
                // Built whether or not this frame has a keypoint op, exactly as the sky
                // homography above is.  A missing keypoint op means the feature file is
                // already on disk, which is a reason to skip *detection*, not a reason
                // to skip the homography that reads it — and this used to `continue` on
                // it, so a resume with cached earth keypoints built no earth homography
                // op for those frames at all.  The merge then found no homography in
                // memory and quietly warped nothing, leaving the ground exactly as it
                // was on a run that had asked for it to be aligned.
                let earthH = HomographyOp(
                  forStars: false,
                  frame: frame,
                  mode: .earthAligned,
                  rawImageBytes: rawImageBytes
                ) { errorString in
                    Task { await errors.append(errorString) }
                    errorClosure(errorString)
                }
                earthH.queuePriority = .veryHigh
                earthH.qualityOfService = .userInteractive

                if let selfEarthKP = earthKeypointOps[frame.frameIndex] {
                    earthH.addDependency(selfEarthKP)
                }

                for neighborIndex in neighbourIndices {
                    if let neighborKP = earthKeypointOps[neighborIndex] {
                        earthH.addDependency(neighborKP)
                    }
                }

                allOps.append(earthH)
                homographyOps.append(earthH)
            }
        }

        // ---- 4. Global validation barrier ----
        // depends upon everything above it
        // knowing all computed neighbor homographies for all frames allows
        // them to be corrected where necessary.
        //
        // Given the frames we built a homography op for, and no others.  Both
        // validation paths write a corrected homography back to every frame they are
        // handed, and a frame outside the range has no computed homography to validate
        // — including it would only overwrite its stored one from a median taken
        // without it.
        let validationOp = AlignmentValidationOp(
          frames: outputFrames,
          configManager: configManager
        ) { errorString in
            Task { await errors.append(errorString) }
            errorClosure(errorString)
        }
        validationOp.qualityOfService = .userInteractive
        Log.d("\(homographyOps.count) homographyOps")
        homographyOps.forEach { validationOp.addDependency($0) }
        allOps.append(validationOp)

        // how many in each direction for final outlier classification.  Clamped at 0:
        // it is a radius, and a negative one would invert the neighbour range below.
        let numOutlierNeighbors = max(0, config.numberFinalProcessingNeighborsNeeded)

        for frame in outputFrames {
            // Outlier operations for selective and auto selective
            // every frame in the range gets an op, but it may be a nop for auto only
            if await frame.usesOutliers {
                // Actual neighbour counts, not the configured ones: calculateNeighborIndices
                // clamps to the sequence bounds, so a frame near either end has fewer —
                // possibly none at all — and charging for the configured count
                // over-reserves.  Both are populated in FrameAirplaneRemover's init, so
                // they are real counts here, never a stand-in for "not known yet".
                let aligned = await frame.numberOfAlignedFrames
                let statics = await frame.getStaticNeighborFrames().count
                let outlierOp = OutlierOp(
                  frame: frame,
                  rawImageBytes: rawImageBytes,
                  memoryMultiplier: UInt64(config.effectiveOutlierMemoryMultiplier(
                                             alignedNeighbours: aligned,
                                             staticNeighbours: statics))
                ) { errorString in
                    Task { await errors.append(errorString) }
                    errorClosure(errorString)
                }

                outlierOp.addDependency(validationOp)
                allOps.append(outlierOp)
                outlierOps[frame.frameIndex] = outlierOp
            }
        }

        // 5. Merge (depends on global validation later)
        // This is the stage that writes each frame's output image, so it runs on
        // exactly the frames that were asked for and no others.
        for frame in outputFrames {

            // Output already written.  This is the test MergeOp has always made as its
            // first act; made here it also keeps the op from reserving
            // `effectiveMergeMemoryMultiplier` × the working frame in order to read one
            // enum.  The frame's own state, not a file check: `.complete` is set from
            // the final image existing at load and cleared by anything that invalidates
            // it, so it means "written and still valid" rather than merely "written".
            if await frame.processingState() == .complete { continue }

            let aligned = await frame.numberOfAlignedFrames
            let statics = await frame.getStaticNeighborFrames().count
            let mergeOp = MergeOp(
              frame: frame,
              rawImageBytes: rawImageBytes,
              memoryMultiplier: UInt64(config.effectiveMergeMemoryMultiplier(
                                         alignedNeighbours: aligned,
                                         staticNeighbours: statics))
            ) { errorString in
                Task { await errors.append(errorString) }
                errorClosure(errorString)
            }

            mergeOp.qualityOfService = .userInteractive
            mergeOp.addDependency(validationOp)


            // add outlier dependencies for neighbor frames; will be a nop
            // if this frame doesn't use outliers.  These are frame-index
            // values, not array indices — clamp against the actual largest
            // frame index in the sequence.
            //
            // A neighbour outside the requested range has no outlier op, so nothing is
            // waited on for it: the frames at the edge of a partial range see the same
            // absent-neighbour decision tree features that the first and last frames of
            // a full sequence already do.
            var startOutlierFrameIndex = frame.frameIndex - numOutlierNeighbors
            var endOutlierFrameIndex = frame.frameIndex + numOutlierNeighbors
            if startOutlierFrameIndex < 0 { startOutlierFrameIndex = 0 }
            if endOutlierFrameIndex > maxFrameIndex { endOutlierFrameIndex = maxFrameIndex }

            for neighborFrameIndex in startOutlierFrameIndex...endOutlierFrameIndex {
                if let outlierOp = outlierOps[neighborFrameIndex] {
                    mergeOp.addDependency(outlierOp)
                }
            }
            
            allOps.append(mergeOp)
            mergeOps.append(mergeOp)
        }

        // 6. runs after all have finished
        // Its dependencies are the merge ops, which now exist only for the requested
        // range, so a partial run reports completion when that range is written rather
        // than waiting on frames it never built an op for.
        let completionOp = GraphCompletionOp {
            Log.i("Frame graph fully finished")
            Log.i(await MemoryMonitor.shared.stats())
            closure(await errors.elements())
        }
        Log.d("\(mergeOps.count) mergeOps")
        mergeOps.forEach { completionOp.addDependency($0) }
        // Validation and the outlier ops as well, not only the merges.
        //
        // A merge op used to be built for every frame in the range, which made it an
        // unconditional descendant of both — so waiting on the merges waited on
        // everything.  Now that a frame whose output is already written gets no merge op,
        // a sequence that is entirely up to date has none at all, and completion would
        // otherwise fire while validation was still running.  Both are cheap to depend on
        // and one of them is already an ancestor of every merge, so this only ever
        // removes a way to report done early.
        completionOp.addDependency(validationOp)
        outlierOps.values.forEach { completionOp.addDependency($0) }
        allOps.append(completionOp)

        await withCheckedContinuation { continuation in
            queue.addOperations(allOps, waitUntilFinished: false)
            continuation.resume()
        }
    }
    
    /// Re-enqueue horizon refinement and merge for the given frames after a
    /// manual horizon reference edit.
    ///
    /// - `refinementFrames`: interpolated frames whose merged horizon mask must
    ///   be recomputed (each gets a `HorizonRefinementOp`).
    /// - `mergeFrames`: frames with existing output that need re-compositing
    ///   with the updated horizon (each gets a `MergeOp` depending on the
    ///   matching refinement op when one exists).
    /// - `refinementCompletion`: per-frame callback fired when each refinement
    ///   op finishes — used by callers to refresh overlays.
    ///
    /// Running everything through the operation queue means refinement honors
    /// `numberOfFramesToProcessConcurrently` and the `MemoryMonitor` budget,
    /// and shows up in the operations panel rather than spawning unbounded
    /// concurrent tasks.
    public func enqueueHorizonRefinement(
      refinementFrames: [FrameAirplaneRemover],
      mergeFrames: [FrameAirplaneRemover],
      refinementCompletion: @escaping @Sendable (FrameAirplaneRemover) async -> Void = { _ in },
      errorClosure: @escaping @Sendable (String) -> Void,
      completion: @escaping @Sendable ([String]) -> Void
    ) async {
        guard let configManager else {
            completion(["cannot enqueue horizon refinement without config manager"])
            return
        }
        let config = await configManager.config()
        // The reservation unit, not the source frame size: multipliers were derived at
        // the 16-bit working depth, so an 8-bit source must not halve them.
        let rawImageBytes = config.workingFrameBytes

        let errors = ArrayActor<String>([])

        var refinementOps: [Int: HorizonRefinementOp] = [:]
        for frame in refinementFrames {
            let op = HorizonRefinementOp(
              frame: frame,
              rawImageBytes: rawImageBytes,
              memoryMultiplier: UInt64(config.effectiveHorizonMemoryMultiplier()),
              errorClosure: { errorString in
                  Task { await errors.append(errorString) }
                  errorClosure(errorString)
              },
              onCompletion: refinementCompletion
            )
            op.qualityOfService = .userInteractive
            refinementOps[frame.frameIndex] = op
        }

        var mergeOps: [MergeOp] = []
        for frame in mergeFrames {
            let aligned = await frame.numberOfAlignedFrames
            let statics = await frame.getStaticNeighborFrames().count
            let mergeOp = MergeOp(
              frame: frame,
              rawImageBytes: rawImageBytes,
              memoryMultiplier: UInt64(config.effectiveMergeMemoryMultiplier(
                                         alignedNeighbours: aligned,
                                         staticNeighbours: statics))
            ) { errorString in
                Task { await errors.append(errorString) }
                errorClosure(errorString)
            }
            mergeOp.qualityOfService = .userInteractive
            if let refinementOp = refinementOps[frame.frameIndex] {
                mergeOp.addDependency(refinementOp)
            }
            mergeOps.append(mergeOp)
        }

        let completionOp = GraphCompletionOp {
            completion(await errors.elements())
        }
        refinementOps.values.forEach { completionOp.addDependency($0) }
        mergeOps.forEach { completionOp.addDependency($0) }

        let sortedRefinements = refinementOps.values
            .sorted { $0.frame.frameIndex < $1.frame.frameIndex }
        let allOps: [Operation] = sortedRefinements + mergeOps + [completionOp]
        await withCheckedContinuation { continuation in
            queue.addOperations(allOps, waitUntilFinished: false)
            continuation.resume()
        }
    }

    /// Cancel all queued and running operations.
    ///
    /// Queued operations are skipped immediately.  Running operations finish
    /// their current async step and then mark themselves finished.  The
    /// `GraphCompletionOp` will be cancelled and its closure will not fire,
    /// so callers that track processing state (e.g. `isProcessingFrames`)
    /// must reset that state themselves after calling this method.
    public func cancelAllOperations() {
        queue.cancelAllOperations()
        previewQueue.cancelAllOperations()
        Log.i("FrameGraphBuilder: all operations cancelled")
    }

    public func debugPrint() {
        Log.d("========== OperationQueue ==========")
        Log.d("Name: \(queue.name ?? "nil")")
        Log.d("Max Concurrent Operation Count: \(queue.maxConcurrentOperationCount)")
        Log.d("Quality of Service: \(queue.qualityOfService)")
        Log.d("Is Suspended: \(queue.isSuspended)")
        Log.d("Operation Count: \(queue.operationCount)")
        Log.d("-------- Preview Queue -------------")
        Log.d("Name: \(previewQueue.name ?? "nil")")
        Log.d("Max Concurrent Operation Count: \(previewQueue.maxConcurrentOperationCount)")
        Log.d("Operation Count: \(previewQueue.operationCount)")
        Log.d("------------------------------------")

        let operations = queue.operations

        for (index, op) in operations.enumerated() {
            Log.d("Operation #\(index):")
            Log.d("  Name: \(op.name ?? "nil")")
            Log.d("  Class: \(type(of: op))")
            Log.d("  isReady: \(op.isReady)")
            Log.d("  isExecuting: \(op.isExecuting)")
            Log.d("  isFinished: \(op.isFinished)")
            Log.d("  isCancelled: \(op.isCancelled)")
            Log.d("  queuePriority: \(op.queuePriority)")
            Log.d("  qualityOfService: \(op.qualityOfService)")
            Log.d("  completionBlock set: \(op.completionBlock != nil)")

            if !op.dependencies.isEmpty {
                Log.d("  Dependencies:")
                for dep in op.dependencies {
                    Log.d("    - \(dep.name ?? "unnamed") [\(type(of: dep))] finished: \(dep.isFinished)")
                }
            } else {
                Log.d("  Dependencies: none")
            }

            Log.d("------------------------------------")
        }

        Log.d("====================================")
    }
}

