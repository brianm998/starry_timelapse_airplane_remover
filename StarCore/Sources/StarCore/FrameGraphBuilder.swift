import Foundation
import logging
/*

 * write homography validation logic for static sky
 * fix alignment graph data
 * expose queue max sizes to config, replace process X frames at once

 Still TODO:

 - write homography validation logic for moving sky and earth
 - more UI update of what's going on (states are only partially reported)
 - deal with FinalGUIProcessor differences
 - deal with selective mode
 - make errors show up in UI (no found keypoints, homography, etc)
 
 */
public final actor FrameGraphBuilder {

    // MARK: Queues (user adjustable)
    let horizonQueue = OperationQueue()
    let keypointQueue = OperationQueue()
    let homographyQueue = OperationQueue()
    let mergeQueue = OperationQueue()

    let configManager: ConfigManager
    
    public init(_ configManager: ConfigManager) async {
        self.configManager = configManager

        update(from: await configManager.config())

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
        Log.d("update from config maxConcurrentHorizonCalculations \(config.maxConcurrentHorizonCalculations) maxConcurrentKeypointCalculations \(config.maxConcurrentKeypointCalculations) maxConcurrentHomographyCalculations \(config.maxConcurrentHomographyCalculations) maxConcurrentMergeCalculations \(config.maxConcurrentMergeCalculations)")
    }
    
    public func build(
        frames: [FrameAirplaneRemover],
        closure: @escaping () -> Void
    ) async {
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
                horizonQueue.addOperation(horizonOp)
                lastOps.append(horizonOp)
            }

            // 2. Keypoints (always sky)
            let skyKP = KeypointOp(frame: frame, mode: .starAligned)
            lastOps.forEach { skyKP.addDependency($0) }
            Log.d("\(lastOps.count) lastOps")
            keypointQueue.addOperation(skyKP)
            skyKeypointOps[frame.frameIndex] = skyKP
            
            // 2b. Earth keypoints (optional)
            if hasHorizon && processEarth {
                let kp = KeypointOp(frame: frame, mode: .earthAligned)
                kp.addDependency(skyKP)
                keypointQueue.addOperation(kp)
                earthKeypointOps[frame.frameIndex] = kp
            }
        }

        // next assemble homography operations that depend upon the keyframes from above
        for frame in frames {
            // 3. Homographies
            let skyH = HomographyOp(frame: frame, mode: .starAligned)

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
        Log.d("\(homographyOps.count) homographyOps")
        homographyOps.forEach { validationOp.addDependency($0) }
        homographyQueue.addOperation(validationOp)

        // 5. Merge (depends on global validation later)
        for frame in frames {
            let mergeOp = MergeOp(frame: frame)
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
