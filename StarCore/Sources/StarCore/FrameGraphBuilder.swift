import Foundation
import logging

public final class FrameGraphBuilder {

    // MARK: Queues (user adjustable)
    let horizonQueue = OperationQueue()
    let keypointQueue = OperationQueue()
    let homographyQueue = OperationQueue()
    let mergeQueue = OperationQueue()

    public init() {
        horizonQueue.maxConcurrentOperationCount = 1
        keypointQueue.maxConcurrentOperationCount = 2
        homographyQueue.maxConcurrentOperationCount = 2
        mergeQueue.maxConcurrentOperationCount = 10
    }

    public func build(
        frames: [FrameContext],
        hasHorizon: Bool,
        processEarth: Bool,
        closure: @escaping () -> Void
    ) {
        var homographyOps: [Operation] = []
        var mergeOps: [Operation] = []

        var skyKeypointOps: [Int: KeypointOp] = [:]
        var earthKeypointOps: [Int: KeypointOp] = [:]

        
        // ---- Per-frame graph ----
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
            skyKeypointOps[frame.index] = skyKP
            
            // 2b. Earth keypoints (optional)
            if hasHorizon && processEarth {
                let kp = KeypointOp(frame: frame, mode: .earthAligned)
                kp.addDependency(skyKP)
                keypointQueue.addOperation(kp)
                earthKeypointOps[frame.index] = kp
            }
        }

        for frame in frames {
            // 3. Homographies
            let skyH = HomographyOp(frame: frame, mode: .starAligned)


            // Depends on this frame's sky keypoints
            if let selfKP = skyKeypointOps[frame.index] {
                skyH.addDependency(selfKP)
            }

            // Depends on neighbors' sky keypoints
            for neighborIndex in frame.neighbors {
                if let neighborKP = skyKeypointOps[neighborIndex] {
                    skyH.addDependency(neighborKP)
                }
            }

            homographyQueue.addOperation(skyH)
            homographyOps.append(skyH)

            // ---- Earth-aligned homography (optional) ----
            if hasHorizon && processEarth {
                guard let selfEarthKP = earthKeypointOps[frame.index] else { continue }

                let earthH = HomographyOp(frame: frame, mode: .earthAligned)
                earthH.addDependency(selfEarthKP)

                for neighborIndex in frame.neighbors {
                    if let neighborKP = earthKeypointOps[neighborIndex] {
                        earthH.addDependency(neighborKP)
                    }
                }

                homographyQueue.addOperation(earthH)
                homographyOps.append(earthH)
            }
        }

        // ---- 4. Global validation barrier ----
        let validationOp = AlignmentValidationOp(frames: frames)
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
