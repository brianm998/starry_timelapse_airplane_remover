import Foundation
import logging

public let frameGraphBuilder = FrameGraphBuilder()

// uses OperationQueues to allow processing with dependencies and configurable max processing  
public final actor FrameGraphBuilder {

    // MARK: Queues (user adjustable)
    let queue = OperationQueue()

    let keypointLimiter = KeypointLimiter(maxConcurrent: 10) // XXX use other value

    public init() {
        queue.name = "operations"
    }
    
    public struct Queues {
        public let queue: OperationQueue
    }

    public nonisolated func queues() -> Queues {
        Queues(
          queue: queue,
        )
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
        Task {
            await keypointLimiter.set(
              maxConcurrent: config.maxConcurrentKeypointCalculations
            )
        }
    }
    
    public func build(
      frames: [FrameAirplaneRemover],
      startIndex: Int = 0,
      endIndex: Int? = nil,      // will be last index of frames
      closure: @escaping ([String]) -> Void,
      errorClosure: @escaping (String) -> Void
    ) async {
        guard let configManager else {
            errorClosure("cannot build without config manager")
            closure(["cannot build without config manager"])
            return
        }

        var errors: [String] = []
        
        let config = await configManager.config()

        let hasHorizon = config.horizonDetectionEnabled
        let processEarth = config.allowEarthAlignment && 
          config.tripodHeadWasMoving // keypoints not used when stationary
        
        var homographyOps: [Operation] = []
        var mergeOps: [Operation] = []

        var skyKeypointOps: [Int: KeypointOp] = [:]
        var earthKeypointOps: [Int: KeypointOp] = [:]

        var outlierOps: [Int: OutlierOp] = [:]

        var lastIndex = frames.count - 1
        if let endIndex { lastIndex = endIndex }

        Log.d("processing from frameIndex \(startIndex) to \(lastIndex)")

        // First assemble horizon, keypoint and outlier operations for all frames
        for frameIndex in startIndex...lastIndex {

            let frame = frames[frameIndex]

            var lastOps: [Operation] = []

            // 1. Horizon
            if hasHorizon {
                let horizonOp = HorizonDetectionOp(frame: frame) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }
                horizonOp.qualityOfService = .userInteractive
                queue.addOperation(horizonOp)
                lastOps.append(horizonOp)
            }

            // 2. Keypoints (always sky)
            let skyKP = KeypointOp(
              frame: frame,
              mode: .starAligned,
              limiter: keypointLimiter
            ) { errorString in
                errors.append(errorString)
                errorClosure(errorString)
            }

            skyKP.qualityOfService = .userInteractive
            lastOps.forEach { skyKP.addDependency($0) }
            Log.d("\(lastOps.count) lastOps")
            queue.addOperation(skyKP)
            skyKeypointOps[frame.frameIndex] = skyKP
            
            // 2b. Earth keypoints (optional)
            if hasHorizon && processEarth {
                let kp = KeypointOp(
                  frame: frame,
                  mode: .earthAligned,
                  limiter: keypointLimiter
                ) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }
                kp.qualityOfService = .userInteractive
                kp.addDependency(skyKP)
                queue.addOperation(kp)
                earthKeypointOps[frame.frameIndex] = kp
            }
        }

        // next assemble homography operations that depend upon the keyframes from above
        for frame in frames {
            // 3. Homographies
            let skyH = HomographyOp(
              frame: frame,
              mode: .starAligned
            ) { errorString in
                errors.append(errorString)
                errorClosure(errorString)
            }
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

            queue.addOperation(skyH)
            homographyOps.append(skyH)

            // ---- Earth-aligned homography (optional) ----
            if hasHorizon && processEarth {
                guard let selfEarthKP = earthKeypointOps[frame.frameIndex] else { continue }

                let earthH = HomographyOp(
                  frame: frame,
                  mode: .earthAligned
                ) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }

                earthH.qualityOfService = .userInteractive
                earthH.addDependency(selfEarthKP)

                for neighborIndex in await frame.getAlignmentFrameIndices() {
                    if let neighborKP = earthKeypointOps[neighborIndex] {
                        earthH.addDependency(neighborKP)
                    }
                }

                queue.addOperation(earthH)
                homographyOps.append(earthH)
            }
        }

        // ---- 4. Global validation barrier ----
        let validationOp = AlignmentValidationOp(
          frames: frames,
          configManager: configManager
        ) { errorString in
            errors.append(errorString)
            errorClosure(errorString)
        }
        validationOp.qualityOfService = .userInteractive
        Log.d("\(homographyOps.count) homographyOps")
        homographyOps.forEach { validationOp.addDependency($0) }
        queue.addOperation(validationOp)

        // how many in each direction for final outlier classification 
        let numOutlierNeighbors = config.numberFinalProcessingNeighborsNeeded            
        
        for frame in frames {
            // Outlier operations for selective and auto selective
            // all frames get an op, but it may be a nop for auto only
            if await frame.usesOutliers {
                let outlierOp = OutlierOp(
                  frame: frame
                ) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }

                outlierOp.addDependency(validationOp)
                queue.addOperation(outlierOp)
                outlierOps[frame.frameIndex] = outlierOp
            }
        }

        // 5. Merge (depends on global validation later)
        for frame in frames {
            
            let mergeOp = MergeOp(
              frame: frame
            ) { errorString in
                errors.append(errorString)
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
            
            queue.addOperation(mergeOp)
            mergeOps.append(mergeOp)
        }

        // add a step here for selecive processing 

        // 6. runs after all have finished
        let completionOp = GraphCompletionOp {
            Log.d("Frame graph fully finished")
            closure(errors)
        }
        Log.d("\(mergeOps.count) mergeOps")
        mergeOps.forEach { completionOp.addDependency($0) }
        queue.addOperation(completionOp)
    }
}
