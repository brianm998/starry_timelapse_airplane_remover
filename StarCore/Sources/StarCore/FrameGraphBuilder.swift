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
        // Fallback only — FrameGraphBuilder always passes config.keypointMemoryMultiplier
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
            return
        }

        let explicit = config.maxConcurrentKeypointOps > 0
            ? ", explicit cap \(config.maxConcurrentKeypointOps)"
            : ""
        Log.i("KeypointLimiter[\(context)]: \(kc.limit) concurrent keypoint ops — " +
              "budget fits \(budgetLimit) " +
              "(image \(config.imageWidth)×\(config.imageHeight)×\(config.imageBytesPerPixel)B, " +
              "working frame \(config.workingFrameBytes/(1024*1024))MB × \(config.keypointMemoryMultiplier) = " +
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

        // The frame-index range to process.  `endIndex` (if given) is a frame
        // index, so cap at the largest frame index we actually have, not at
        // `frames.count - 1`.
        let maxFrameIndex = frames.map(\.frameIndex).max() ?? (startIndex - 1)
        var lastIndex = maxFrameIndex
        if let endIndex { lastIndex = min(endIndex, maxFrameIndex) }

        var allOps: [Operation] = []

        Log.d("processing from frameIndex \(startIndex) to \(lastIndex)")

        // For static sequences without a reference horizon, create a shared accumulator
        // so that HorizonDetectionOps feed their results in as they complete, avoiding
        // a full disk reload of all masks during the later HorizonMergeOp.
        if hasHorizon && !hasStaticReferenceHorizon && !config.tripodHeadWasMoving {
            // HorizonAccumulator sizes its internal table by frameCount and
            // indexes it directly by frameIndex, so it must cover up through
            // the largest frame index in the sequence.
            let accumulator = HorizonAccumulator(frameCount: maxFrameIndex + 1)
            for frameIndex in startIndex...lastIndex {
                if let frame = framesByIndex[frameIndex] {
                    await frame.setHorizonAccumulator(accumulator)
                }
            }
            Log.i("created HorizonAccumulator for \(frames.count) frames")
        }

        // First assemble initial horizon operations,
        // with no dependencies upon any other operations.
        // Skipped when the user has painted a global reference for a static sequence.
        let horizonOps = await withTaskGroup(
          of: HorizonDetectionOp?.self
        ) { taskGroup in
            for frameIndex in startIndex...lastIndex {
                guard let frame = framesByIndex[frameIndex] else { continue }
                taskGroup.addTask() {
                    // 1. Horizon
                    if hasHorizon && !hasStaticReferenceHorizon {
                        let horizonOp = HorizonDetectionOp(
                          frame: frame,
                          rawImageBytes: rawImageBytes,
                          memoryMultiplier: UInt64(config.effectiveHorizonMemoryMultiplier())
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
                    for frameIndex in startIndex...lastIndex {
                        guard let frame = framesByIndex[frameIndex] else { continue }
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
                guard let frame = framesByIndex[startIndex] else {
                    Log.e("no frame at startIndex \(startIndex), cannot create static HorizonMergeOp")
                    return
                }
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
                mergedHorizonOps[startIndex] = horizonOp
                for op in horizonOps.values {
                    horizonOp.addDependency(op)
                }
                allOps.append(horizonOp)
            }
        }

        skyKeypointOps = await withTaskGroup(
          of: KeypointOp.self
        ) { taskGroup in
            // Keypoints depend upon the merged horizon mask for their index
            for frameIndex in startIndex...lastIndex {
                guard let frame = framesByIndex[frameIndex] else { continue }
                taskGroup.addTask {
                    // 2. Keypoints (always sky)
                    let skyKP = KeypointOp(
                      forStars: true,
                      frame: frame,
                      mode: .starAligned,
                      limiter: self.keypointLimiter,
                      rawImageBytes: rawImageBytes,
                      memoryMultiplier: UInt64(config.keypointMemoryMultiplier)
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
                        if let horizonOp = mergedHorizonOps[startIndex] {
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
                for frameIndex in startIndex...lastIndex {
                    guard let frame = framesByIndex[frameIndex] else { continue }
                    taskGroup.addTask {
                        // 2b. Earth keypoints (optional)
                        let kp = KeypointOp(
                          forStars: false,
                          frame: frame,
                          mode: .earthAligned,
                          limiter: self.keypointLimiter,
                          rawImageBytes: rawImageBytes,
                          memoryMultiplier: UInt64(config.keypointMemoryMultiplier)
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
        for frame in frames {
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

            // Depends on neighbors' sky keypoints
            for neighborIndex in await frame.getAlignmentFrameIndices() {
                if let neighborKP = skyKeypointOps[neighborIndex] {
                    skyH.addDependency(neighborKP)
                }
            }

            allOps.append(skyH)
            homographyOps.append(skyH)

            // ---- Earth-aligned homography (optional) ----
            if hasHorizon && processEarth {
                guard let selfEarthKP = earthKeypointOps[frame.frameIndex] else { continue }

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
                earthH.addDependency(selfEarthKP)

                for neighborIndex in await frame.getAlignmentFrameIndices() {
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
        let validationOp = AlignmentValidationOp(
          frames: frames,
          configManager: configManager
        ) { errorString in
            Task { await errors.append(errorString) }
            errorClosure(errorString)
        }
        validationOp.qualityOfService = .userInteractive
        Log.d("\(homographyOps.count) homographyOps")
        homographyOps.forEach { validationOp.addDependency($0) }
        allOps.append(validationOp)

        // how many in each direction for final outlier classification
        let numOutlierNeighbors = config.numberFinalProcessingNeighborsNeeded

        for frame in frames {
            // Outlier operations for selective and auto selective
            // all frames get an op, but it may be a nop for auto only
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
        for frame in frames {

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
        let completionOp = GraphCompletionOp {
            Log.i("Frame graph fully finished")
            Log.i(await MemoryMonitor.shared.stats())
            closure(await errors.elements())
        }
        Log.d("\(mergeOps.count) mergeOps")
        mergeOps.forEach { completionOp.addDependency($0) }
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

