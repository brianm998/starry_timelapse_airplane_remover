import Foundation
import logging
/*

 * write homography validation logic for static sky
 * fix alignment graph data
 * expose queue max sizes to config, replace process X frames at once
 * see why config params don't seem to be updating
 * write homography validation logic for moving sky and earth
 * make errors show up in UI (no found keypoints, homography, etc)

 Still TODO:

 - make sure static ground merge is still happening
 - more UI update of what's going on (states are only partially reported)
 - deal with FinalGUIProcessor differences
 - deal with selective mode
 - hook up to CLI
 - final render re-renders when file is already there (after re-start)
 
 */

public let frameGraphBuilder = FrameGraphBuilder()

public final actor FrameGraphBuilder {

    // MARK: Queues (user adjustable)
    let horizonQueue = OperationQueue()
    let keypointQueue = OperationQueue()
    let homographyQueue = OperationQueue()
    let mergeQueue = OperationQueue()

    public init() {
        horizonQueue.name = "horizons"
        keypointQueue.name = "keypoints"
        homographyQueue.name = "alignment"
        mergeQueue.name = "merging"
    }
    
    public struct Queues {
        public let horizon: OperationQueue
        public let keypoint: OperationQueue
        public let homography: OperationQueue
        public let merge: OperationQueue
    }

    public nonisolated func queues() -> Queues {
        Queues(
          horizon: horizonQueue,
          keypoint: keypointQueue,
          homography: homographyQueue,
          merge: mergeQueue
        )
    }
    
    var configManager: ConfigManager? = nil

    func set(configManager: ConfigManager) async {
        self.configManager = configManager
        self.update(from: await configManager.config())
        await configManager.onUpdate { [weak self] config in
            Task {
                await self?.update(from: config)
            }
        }
    }
    
    public func update(from config: Config) {
        horizonQueue.maxConcurrentOperationCount = config.maxConcurrentHorizonCalculations
        keypointQueue.maxConcurrentOperationCount = config.maxConcurrentKeypointCalculations
        homographyQueue.maxConcurrentOperationCount = config.maxConcurrentHomographyCalculations
        mergeQueue.maxConcurrentOperationCount = config.maxConcurrentMergeCalculations
    }
    
    public func build(
        frames: [FrameAirplaneRemover],
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

        // First assemble horizon and keypoint operations for all frames
        for frame in frames {

            var lastOps: [Operation] = []

            // 1. Horizon
            if hasHorizon {
                let horizonOp = HorizonDetectionOp(frame: frame) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }
                horizonOp.qualityOfService = .userInteractive
                horizonQueue.addOperation(horizonOp)
                lastOps.append(horizonOp)
            }

            // 2. Keypoints (always sky)
            let skyKP = KeypointOp(
              frame: frame,
              mode: .starAligned
            ) { errorString in
                errors.append(errorString)
                errorClosure(errorString)
            }

            skyKP.qualityOfService = .userInteractive
            lastOps.forEach { skyKP.addDependency($0) }
            Log.d("\(lastOps.count) lastOps")
            keypointQueue.addOperation(skyKP)
            skyKeypointOps[frame.frameIndex] = skyKP
            
            // 2b. Earth keypoints (optional)
            if hasHorizon && processEarth {
                let kp = KeypointOp(
                  frame: frame,
                  mode: .earthAligned
                ) { errorString in
                    errors.append(errorString)
                    errorClosure(errorString)
                }
                kp.qualityOfService = .userInteractive
                kp.addDependency(skyKP)
                keypointQueue.addOperation(kp)
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

            homographyQueue.addOperation(skyH)
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

                homographyQueue.addOperation(earthH)
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
        homographyQueue.addOperation(validationOp)

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
            mergeQueue.addOperation(mergeOp)
            mergeOps.append(mergeOp)
        }

        // 6. runs after all have finished
        let completionOp = GraphCompletionOp {
            Log.d("Frame graph fully finished")
            closure(errors)
        }
        Log.d("\(mergeOps.count) mergeOps")
        mergeOps.forEach { completionOp.addDependency($0) }
        mergeQueue.addOperation(completionOp)
    }
}
