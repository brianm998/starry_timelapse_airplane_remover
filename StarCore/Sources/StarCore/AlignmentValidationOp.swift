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

        guard !results.isEmpty else {
            Log.e("No homography results found")
            return
        }

        Log.d("Running RTS pose smoother")
        let poses = smoothHomographyPosesRTS(
          results: results,
          smoothness: 0.2
        )

        for frame in frames {
            guard let original = await frame.getNeighborStarHomography() else { continue }

            Log.d("frame \(frame.frameIndex) FUCKING rebuildHomographies")
            
            let rebuilt = rebuildHomographies(
              original: original,
              poses: poses,
              allResults: results
            )

            await frame.set(neighborStarHomography: rebuilt)
        }

        Log.d("validateMovingStarAlignment done")
    }
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

struct RelativeObservation {
    let from: Int
    let to: Int
    let delta: [Double]
    let weight: Double
}

func buildRelativeObservations(
  results: [HomographyResultsCodable]
) -> [RelativeObservation] {

    var obs: [RelativeObservation] = []

    for result in results {
        let t = result.frameIndex

        for warp in result.neighborHomography {
            guard
              let h = warp.homography,
              warp.alignmentState == .homographySuccess
            else {
                Log.d("FUCKING BAD WARP")
                continue
            }

            let n = warp.frameIndex
            let delta = HomographyLieMapping.log(h)

            let w = max(0.1, 1.0 / (warp.deviation + 1e-6))

            obs.append(
              RelativeObservation(
                from: t,
                to: n,
                delta: delta,
                weight: w
              )
            )
        }
    }
    Log.d("FUCKING returning \(obs.count) when given \(results.count)")
    return obs
}

func rebuildHomographies(
  original: HomographyResultsCodable,
  poses: [Int: [Double]],
  allResults: [HomographyResultsCodable]
) -> HomographyResultsCodable {

    let t = original.frameIndex
    guard let poseT = poses[t] else {
        Log.d("FUCKING NO POSE")
        return original
    }

    let expectedDev = expectedDeviation(
        at: t,
        results: allResults
    )

    var rebuilt: [AlignmentWarpInfoCodable] = []
    Log.d("FUCKING original.neighborHomography.count \(original.neighborHomography.count)")
    for warp in original.neighborHomography {

        // 1️⃣ Keep already-good warps untouched
        if warp.alignmentState == .homographySuccess,
           warp.deviation < 3.0 {
            rebuilt.append(warp)
            Log.i("FUCKING 1")
            continue
        }

        guard
          warp.alignmentState == .homographySuccess,
          let poseN = poses[warp.frameIndex]
        else {
            rebuilt.append(warp)
            Log.i("FUCKING 3")
            continue
        }

        let delta = sub(poseN, poseT)
        let h = HomographyLieMapping.exp(delta)
        let dev = homographyDeviation(h)

        // 2️⃣ Only accept if it improves AND fits curvature
        let accept: Bool = {
            guard let expectedDev else {
                return dev < warp.deviation
            }
            Log.i("FUCKING 3")

            return dev < warp.deviation &&
                   abs(dev - expectedDev) < expectedDev * 0.5
        }()

        Log.i("FUCKING really rebuilding")
        rebuilt.append(
          accept
          ? AlignmentWarpInfoCodable(
              homography: h,
              deviation: dev,
              alignmentState: .homographySuccess,
              frameIndex: warp.frameIndex
            )
          : warp
        )
    }

    return HomographyResultsCodable(for: t, with: rebuilt)
}

func expectedDeviation(
  at frame: Int,
  results: [HomographyResultsCodable],
  radius: Int = 5
) -> Double? {

    let nearby = results.filter {
        frameIsReliable($0) &&
        abs($0.frameIndex - frame) <= radius
    }

    guard !nearby.isEmpty else { return nil }

    return nearby
        .map(\.compositeDeviation)
        .reduce(0, +) / Double(nearby.count)
}

func frameIsReliable(_ r: HomographyResultsCodable) -> Bool {
    r.alignmentLooksOk &&
//    r.compositeDeviation < 30.0 &&   // tune
    r.neighborHomography.count >= 3
}

func smoothHomographyPosesRTS(
  results: [HomographyResultsCodable],
  smoothness: Double = 0.2,
  iterations: Int = 40
) -> [Int: [Double]] {

    let reliable = results.filter(frameIsReliable)
    Log.d("RTS: \(reliable.count) reliable frames")

    guard let anchorResult =
        reliable.min(by: { $0.compositeDeviation < $1.compositeDeviation })
    else {
        Log.e("RTS: no anchor frame")
        return [:]
    }

    let frameIndices = results.map(\.frameIndex).sorted()
    let observations = buildRelativeObservations(results: reliable)

    var poses: [Int: [Double]] = [:]

    let anchor = anchorResult.frameIndex
    poses[anchor] = zeroPose()

    Log.d("RTS: anchor at frame \(anchor)")

    // --- BOOTSTRAP FORWARD ---
    for t in frameIndices where t > anchor {
        if let obs = observations.first(where: { $0.from == t - 1 && $0.to == t }),
           let pPrev = poses[t - 1]
        {
            Log.d("CRAPPY frame \(t) has obs")
            poses[t] = add(pPrev, obs.delta)
        } else {
            Log.d("CRAPPY frame \(t) has NO obs poses[t - 1] \(poses[t - 1])")
            poses[t] = poses[t - 1] ?? zeroPose()
        }
    }

    // --- BOOTSTRAP BACKWARD ---
    for t in frameIndices.reversed() where t < anchor {
        if let obs = observations.first(where: { $0.from == t && $0.to == t + 1 }),
           let pNext = poses[t + 1]
        {
            poses[t] = sub(pNext, obs.delta)
            Log.d("CRAPPY frame \(t) has obs")
        } else {
            Log.d("CRAPPY frame \(t) has NO obs poses[t + 1] \(poses[t + 1])")
            poses[t] = poses[t + 1] ?? zeroPose()
        }
    }

    // --- ITERATIVE RELATIVE SMOOTHING ---
    for iter in 0..<iterations {
        var next = poses

        for obs in observations {
            guard
              let pFrom = poses[obs.from],
              let pTo   = poses[obs.to]
            else { continue }

            let predictedTo = add(pFrom, obs.delta)
            let error = sub(predictedTo, pTo)

            let correction = scale(error, obs.weight * smoothness)

            next[obs.to]   = add(pTo, correction)
            next[obs.from] = sub(pFrom, correction)
        }

        poses = next

        if iter % 10 == 0 {
            Log.d("RTS iter \(iter)")
        }
    }

    for t in frameIndices {
        Log.d("POSE[\(t)] norm = \(poses[t]!.map { abs($0) }.reduce(0,+))")
    }
    
    Log.d("RTS: returning \(poses.count) poses")

    return poses
}
