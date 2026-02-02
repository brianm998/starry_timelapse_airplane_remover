import Foundation
import logging
/*

 * write homography validation logic for static sky
 * fix alignment graph data
 * expose queue max sizes to config, replace process X frames at once

 Still TODO:

 - see why config params don't seem to be updating
 - make sure static ground merge is still happening
 - make errors show up in UI (no found keypoints, homography, etc)
 - more UI update of what's going on (states are only partially reported)
 - deal with FinalGUIProcessor differences
 - deal with selective mode
 - write homography validation logic for moving sky and earth
 - hook up to CLI

 
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
        Log.d("update from config maxConcurrentHorizonCalculations \(config.maxConcurrentHorizonCalculations) horizonQueue.maxConcurrentOperationCount \(horizonQueue.maxConcurrentOperationCount) maxConcurrentKeypointCalculations \(config.maxConcurrentKeypointCalculations) keypointQueue.maxConcurrentOperationCount \(keypointQueue.maxConcurrentOperationCount) maxConcurrentHomographyCalculations \(config.maxConcurrentHomographyCalculations) homographyQueue.maxConcurrentOperationCount \(homographyQueue.maxConcurrentOperationCount) maxConcurrentMergeCalculations \(config.maxConcurrentMergeCalculations) mergeQueue.maxConcurrentOperationCount \(mergeQueue.maxConcurrentOperationCount)")
    }
    
    public func build(
        frames: [FrameAirplaneRemover],
        closure: @escaping () -> Void
    ) async {
        guard let configManager else {
            Log.e("cannot build without config manager")
            closure()
            return
        }
        
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
                let horizonOp = HorizonDetectionOp(frame: frame)
                horizonOp.qualityOfService = .userInteractive
                horizonQueue.addOperation(horizonOp)
                lastOps.append(horizonOp)
            }

            // 2. Keypoints (always sky)
            let skyKP = KeypointOp(frame: frame, mode: .starAligned)
            skyKP.qualityOfService = .userInteractive
            lastOps.forEach { skyKP.addDependency($0) }
            Log.d("\(lastOps.count) lastOps")
            keypointQueue.addOperation(skyKP)
            skyKeypointOps[frame.frameIndex] = skyKP
            
            // 2b. Earth keypoints (optional)
            if hasHorizon && processEarth {
                let kp = KeypointOp(frame: frame, mode: .earthAligned)
                kp.qualityOfService = .userInteractive
                kp.addDependency(skyKP)
                keypointQueue.addOperation(kp)
                earthKeypointOps[frame.frameIndex] = kp
            }
        }

        // next assemble homography operations that depend upon the keyframes from above
        for frame in frames {
            // 3. Homographies
            let skyH = HomographyOp(frame: frame, mode: .starAligned)
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

                let earthH = HomographyOp(frame: frame, mode: .earthAligned)
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
        )
        validationOp.qualityOfService = .userInteractive
        Log.d("\(homographyOps.count) homographyOps")
        homographyOps.forEach { validationOp.addDependency($0) }
        homographyQueue.addOperation(validationOp)

        // 5. Merge (depends on global validation later)
        for frame in frames {
            let mergeOp = MergeOp(frame: frame)
            mergeOp.qualityOfService = .userInteractive
            mergeOp.addDependency(validationOp)
            mergeQueue.addOperation(mergeOp)
            mergeOps.append(mergeOp)
        }

        // 6. runs after all have finished
        let completionOp = GraphCompletionOp {
            Log.d("Frame graph fully finished")
            closure()
        }
        Log.d("\(mergeOps.count) mergeOps")
        mergeOps.forEach { completionOp.addDependency($0) }
        mergeQueue.addOperation(completionOp)
    }
}
