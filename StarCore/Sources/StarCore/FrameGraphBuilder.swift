import Foundation
import logging

public let frameGraphBuilder = FrameGraphBuilder()

public enum OperationType: String, CaseIterable, Sendable {
    case preview
    case horizon
    case mergedHorizon
    case refinedHorizon = "refine horizon"
    case starKeypoints = "star kp"
    case earthKeypoints = "earth kp"
    case starHomography = "star align"
    case earthHomography = "earth align"
    case alignmentValidation
    case outliers
    case merge
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

    let keypointLimiter = KeypointLimiter(max: 10) // XXX use other value

    public init() {
        queue.name = "operations"
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
        keypointLimiter.set(
          max: config.maxConcurrentKeypointCalculations
        )
    }

    public func add(operation: Operation) {
        queue.addOperation(operation)
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

        let hasHorizon = config.horizonDetectionEnabled
        let processEarth = config.allowEarthAlignment && 
          config.tripodHeadWasMoving // keypoints not used when stationary

        var mergedHorizonOps: [Int: Operation] = [:]
        var homographyOps: [Operation] = []
        var mergeOps: [Operation] = []

        var skyKeypointOps: [Int: Operation] = [:]
        var earthKeypointOps: [Int: Operation] = [:]

        var horizonRefinementOps: [Int: Operation] = [:]
        var outlierOps: [Int: OutlierOp] = [:]

        var lastIndex = frames.count - 1
        if let endIndex { lastIndex = endIndex }

        var allOps: [Operation] = []
        
        Log.d("processing from frameIndex \(startIndex) to \(lastIndex)")

        // First assemble initial horizon operations,
        // with no dependencies upon any other operations
        let horizonOps = await withTaskGroup(
          of: HorizonDetectionOp?.self
        ) { taskGroup in
            for frameIndex in startIndex...lastIndex {
                taskGroup.addTask() {
                    let frame = frames[frameIndex]

                    // 1. Horizon
                    if hasHorizon {
                        let horizonOp = HorizonDetectionOp(frame: frame) { errorString in
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
        // original horizon operations from above
        if hasHorizon {
            if config.tripodHeadWasMoving {
                /*
                 Moving tripods have separate HorizonMergsOps for each frame,
                 gathering the masks of a set of neighbors.
                 */
                mergedHorizonOps = await withTaskGroup(
                  of: HorizonMergeOp.self
                ) { taskGroup in
                    for frameIndex in startIndex...lastIndex {
                        taskGroup.addTask {
                            let frame = frames[frameIndex]
                            
                            let horizonOp = HorizonMergeOp(frame: frame) { errorString in
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
                let frame = frames[startIndex]
                let horizonOp = HorizonMergeOp(frame: frame) { errorString in
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
                let frame = frames[frameIndex]
                taskGroup.addTask {
                    // 2. Keypoints (always sky)
                    let skyKP = KeypointOp(
                      forStars: true,
                      frame: frame,
                      mode: .starAligned,
                      limiter: self.keypointLimiter
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
                    let frame = frames[frameIndex]
                    taskGroup.addTask {
                        // 2b. Earth keypoints (optional)
                        let kp = KeypointOp(
                          forStars: false,
                          frame: frame,
                          mode: .earthAligned,
                          limiter: self.keypointLimiter
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
              mode: .starAligned
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
                  mode: .earthAligned
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

        // ---- 4b. Horizon refinement (per-frame, after validated homography) ----
        // Only run when horizon detection is enabled; HorizonRefinementOp
        // falls back to the merged horizon when homography is unavailable.
        if hasHorizon {
            for frame in frames {
                let refinementOp = HorizonRefinementOp(
                  frame: frame
                ) { errorString in
                    Task { await errors.append(errorString) }
                    errorClosure(errorString)
                }
                refinementOp.qualityOfService = .userInteractive
                refinementOp.addDependency(validationOp)
                allOps.append(refinementOp)
                horizonRefinementOps[frame.frameIndex] = refinementOp
            }
        }

        // how many in each direction for final outlier classification
        let numOutlierNeighbors = config.numberFinalProcessingNeighborsNeeded

        for frame in frames {
            // Outlier operations for selective and auto selective
            // all frames get an op, but it may be a nop for auto only
            if await frame.usesOutliers {
                let outlierOp = OutlierOp(
                  frame: frame
                ) { errorString in
                    Task { await errors.append(errorString) }
                    errorClosure(errorString)
                }

                outlierOp.addDependency(validationOp)
                // also depend on this frame's horizon refinement so the
                // refined horizon is available for outlier classification
                if let refinementOp = horizonRefinementOps[frame.frameIndex] {
                    outlierOp.addDependency(refinementOp)
                }
                allOps.append(outlierOp)
                outlierOps[frame.frameIndex] = outlierOp
            }
        }

        // 5. Merge (depends on global validation later)
        for frame in frames {
            
            let mergeOp = MergeOp(
              frame: frame
            ) { errorString in
                Task { await errors.append(errorString) }
                errorClosure(errorString)
            }

            mergeOp.qualityOfService = .userInteractive
            mergeOp.addDependency(validationOp)


            // add outlier dependencies for all frames, will be a nop if not using outliers
            var startOutlierIndex = frame.frameIndex - numOutlierNeighbors
            var endOutlierIndex = frame.frameIndex + numOutlierNeighbors
            if startOutlierIndex < 0 { startOutlierIndex = 0 }
            if endOutlierIndex >= frames.count { endOutlierIndex = frames.count - 1 }

            for i in startOutlierIndex...endOutlierIndex {
                if let outlierOp = outlierOps[i] {
                    mergeOp.addDependency(outlierOp)
                }
            }
            
            allOps.append(mergeOp)
            mergeOps.append(mergeOp)
        }

        // 6. runs after all have finished
        let completionOp = GraphCompletionOp {
            Log.d("Frame graph fully finished")
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
    
    public func debugPrint() {
        Log.d("========== OperationQueue ==========")
        Log.d("Name: \(queue.name ?? "nil")")
        Log.d("Max Concurrent Operation Count: \(queue.maxConcurrentOperationCount)")
        Log.d("Quality of Service: \(queue.qualityOfService)")
        Log.d("Is Suspended: \(queue.isSuspended)")
        Log.d("Operation Count: \(queue.operationCount)")
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

