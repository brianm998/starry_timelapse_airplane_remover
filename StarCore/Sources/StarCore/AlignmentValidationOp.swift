import Foundation
import logging

/*
 This operation takes the full detected homography for the entire sequence,
 and then cleans it up to make sure it is not wrong anywhere.
 */
final class AlignmentValidationOp: AsyncOperation, @unchecked Sendable {
    let frames: [FrameAirplaneRemover]
    let configManager: ConfigManager
    
    init(frames: [FrameAirplaneRemover], configManager: ConfigManager) {
        self.frames = frames
        self.configManager = configManager
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("end")
                finish()
            }

            Log.d("start")
            let config = await configManager.config()
            if config.tripodHeadWasMoving {
                await validateMovingStarAlignment()
            } else {
                // tripod was stationary
                try await self.validateStaticStarAlignment()
            }

            // XXX still need to handle earth alignment if enabled
        }
    }

    // runs on a static sequence after homography is known for each frame and its neighbors
    // finds the 'best' homography and applies it to all frames, to keep the video smooth.
    public func validateStaticStarAlignment() async throws {
        Log.d("doing static star alignment validation")
        var homographies: [HomographyResultsCodable] = []
        for frame in frames {
            if let homography = await frame.getNeighborStarHomography(),
               homography.alignmentLooksOk
            {
                homographies.append(homography)
            }
        }
        if homographies.count == 0 {
            Log.e("ERROR, canceling no homographies found")
            self.cancel()
            // have this abort the operation
            return
        }
        Log.d("found \(homographies.count) neighbor homography groups")

        // sort by composite deviation (average deviation per once frame distance)
        homographies.sort { $0.compositeDeviation < $1.compositeDeviation }

        let medianHomography = homographies[homographies.count/2]
        Log.d("found median homography at frameIndex \(medianHomography.frameIndex)")
        
        // apply the chosen median homography to all frames 
        for frame in frames {
            await frame.set(
              neighborStarHomography:
                medianHomography.adjust(
                  for: frame.frameIndex
                )
            )
        }
        Log.d("done validating static star alignment")
    }

    func validateMovingStarAlignment() async {

        Log.d("validateMovingStarAlignment")
        var results: [HomographyResultsCodable] = []

        for frame in frames {
            if let r = await frame.getNeighborStarHomography() {
                results.append(r)
            }
        }

        Log.d("validateMovingStarAlignment collecting constraints")
        let constraints = collectConstraints(results: results)
        Log.d("validateMovingStarAlignment constraints collected")

        let frameIndices = results.map { $0.frameIndex }.sorted()

        let poses = smoothPoses(
          frameIndices: frameIndices,
          constraints: constraints,
          iterations: 60,
          smoothness: 0.2
        )
        Log.d("validateMovingStarAlignment smoothing complete")

        for frame in frames {
            
            Log.d("frame \(frame.frameIndex) rebuilding homographies")
            guard let original = await frame.getNeighborStarHomography() else { continue }

            let rebuilt = rebuildHomographies(
              original: original,
              poses: poses
            )

            await frame.set(neighborStarHomography: rebuilt)
        }
        Log.d("validateMovingStarAlignment done")
    }
}


func smoothPoses(
  frameIndices: [Int],
  constraints: [PoseConstraint],
  iterations: Int = 50,
  smoothness: Double = 0.1
) -> [Int: [Double]] {

    Log.d("smoothPoses")
    var poses: [Int: [Double]] = [:]

    // Anchor first frame at identity
    if let first = frameIndices.first {
        poses[first] = zeroPose()
    }

    // Initialize others by propagation
    for t in frameIndices.dropFirst() {
        poses[t] = poses[t - 1] ?? zeroPose()
    }

    let neighborsByT = Dictionary(grouping: constraints, by: { $0.t })
    let neighborsByN = Dictionary(grouping: constraints, by: { $0.n })

    for iterationNumber in 0..<iterations {
        Log.d("smoothPoses iteration  \(iterationNumber)")
        var next = poses

        for t in frameIndices {
            guard let pT = poses[t] else { continue }

            Log.d("frameIndex \(t) smoothPoses iteration  \(iterationNumber)")
            var accum = zeroPose()
            var wsum = 0.0

            // Data constraints
            for c in neighborsByT[t] ?? [] {
                if let pN = poses[c.n] {
                    let estimate = add(pN, c.delta)
                    accum = add(accum, scale(estimate, c.weight))
                    wsum += c.weight
                }
            }

            for c in neighborsByN[t] ?? [] {
                if let pT2 = poses[c.t] {
                    let estimate = sub(pT2, c.delta)
                    accum = add(accum, scale(estimate, c.weight))
                    wsum += c.weight
                }
            }

            // Smoothness
            if let pPrev = poses[t - 1] {
                accum = add(accum, scale(pPrev, smoothness))
                wsum += smoothness
            }
            if let pNext = poses[t + 1] {
                accum = add(accum, scale(pNext, smoothness))
                wsum += smoothness
            }

            if wsum > 0 {
                next[t] = scale(accum, 1.0 / wsum)
            }
        }

        poses = next
    }

    return poses
}

func rebuildHomographies(
  original: HomographyResultsCodable,
  poses: [Int: [Double]]
) -> HomographyResultsCodable {

    let t = original.frameIndex
    guard let poseT = poses[t] else { return original }

    var rebuilt: [AlignmentWarpInfoCodable] = []

    for warp in original.neighborHomography {
        let n = warp.frameIndex
        guard let poseN = poses[n] else { continue }

        let delta = sub(poseN, poseT)
        let h = HomographyLieMapping.exp(delta)

        rebuilt.append(
          AlignmentWarpInfoCodable(
            homography: h,
            deviation: homographyDeviation(h),
            alignmentState: .homographySuccess,
            frameIndex: n
          )
        )
    }

    return HomographyResultsCodable(
      for: t,
      with: rebuilt
    )
}


struct PoseConstraint {
    let t: Int
    let n: Int
    let delta: [Double]
    let weight: Double
}

func collectConstraints(
  results: [HomographyResultsCodable]
) -> [PoseConstraint] {

    var constraints: [PoseConstraint] = []

    for result in results {
        let t = result.frameIndex

        for warp in result.neighborHomography {
            guard
              let h = warp.homography,
              warp.alignmentState == .homographySuccess
            else { continue }

            let n = warp.frameIndex
            let delta = HomographyLieMapping.log(h)

            let weight = max(0.1, 1.0 / (warp.deviation + 1e-6))

            constraints.append(
              PoseConstraint(
                t: t,
                n: n,
                delta: delta,
                weight: weight
              )
            )
        }
    }

    return constraints
}

let poseDim = 8

func zeroPose() -> [Double] {
    Array(repeating: 0.0, count: poseDim)
}

func add(_ a: [Double], _ b: [Double]) -> [Double] {
    zip(a, b).map(+)
}

func sub(_ a: [Double], _ b: [Double]) -> [Double] {
    zip(a, b).map(-)
}

func scale(_ a: [Double], _ s: Double) -> [Double] {
    a.map { $0 * s }
}
