import Foundation
import logging

/*
 This operation takes the full detected homography for the entire sequence,
 and then cleans it up to make sure it is not wrong anywhere.
 */
final class AlignmentValidationOp: AsyncOperation, @unchecked Sendable {
    let frames: [FrameAirplaneRemover]
    let configManager: ConfigManager
    let errorClosure: (String) -> Void
    
    init(
      frames: [FrameAirplaneRemover],
      configManager: ConfigManager,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frames = frames
        self.configManager = configManager
        self.errorClosure = errorClosure
        super.init(for: .alignmentValidation)
        self.name = "alignment validation"
    }

    override func asyncExecute() async {
        do {
            Log.d("start")
            let config = await configManager.config()
            if config.tripodHeadWasMoving {
                await validateMovingStarAlignment()
            } else {
                // tripod was stationary
                try await self.validateStaticStarAlignment()
            }
        } catch {
            let str = "error during alignment validation: \(error)"
            Log.e(str)
            errorClosure(str)
        }
        // XXX still need to handle earth alignment if enabled
        Log.d("end")
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
            errorClosure("no homographies found")
            self.cancel()
            // have this abort the operation
            return
        }
        Log.d("found \(homographies.count) neighbor homography groups")

        // sort by composite deviation (average deviation per once frame distance)
        homographies.sort { $0.compositeDeviation < $1.compositeDeviation }

        let medianHomography = homographies[homographies.count/2]
        Log.d("found median homography at frameIndex \(medianHomography.frameIndex)")

        let config = await configManager.config()

        // apply the chosen median homography to all frames 
        for frame in frames {
            // only if this frame has the standard number of neighbor frames
            // ignore ones which have been set differently 
            if !config.overriddenNeighborCount(for: frame.frameIndex) {
                await frame.set(
                  neighborStarHomography:
                    medianHomography.adjust(
                      for: frame.frameIndex
                    )
                )
            }
        }
        Log.d("done validating static star alignment")
    }


    func validateMovingStarAlignment() async {
        Log.d("validateMovingStarAlignment (gap-fill approach) \(frames.count) frames")

        // Build entries that stay parallel to `frames`.  Frames whose
        // homography is missing are kept (homography == nil) and treated as
        // bad — squashing them out would mis-align array indices with the
        // frames array and we would write each fixed homography to the wrong
        // FrameAirplaneRemover.  Each entry carries its own frame so we never
        // need to look up `frames[idx]` from a homography-array index.
        var entries: [GapFillEntry] = []
        for frame in frames {
            // also remember each frame's neighbor structure up front, since
            // for nil-homography entries we still need it when retargeting
            // a good homography onto this frame.
            let homography = await frame.getNeighborStarHomography()
            let neighborFrameIndices = await frame.getAlignmentFrameIndices()
            entries.append(
              GapFillEntry(
                frame: frame,
                homography: homography,
                neighborFrameIndices: neighborFrameIndices
              )
            )
        }

        let nonNilCount = entries.lazy.filter { $0.homography != nil }.count
        guard nonNilCount > 0 else {
            Log.e("No homography results found")
            errorClosure("no homographies found")
            self.cancel()
            return
        }
        Log.d("validateMovingStarAlignment (gap-fill approach) \(nonNilCount) homographies of \(entries.count) frames")

        // Classify frames — nil homography is automatically bad.
        let goodFlags: [Bool] = entries.map { entry in
            guard let h = entry.homography else { return false }
            return isGood(h)
        }

        Log.d("found \(goodFlags.filter { $0 }.count) good flags out of \(entries.count)")

        // Find contiguous bad segments
        var i = 0
        while i < entries.count {

            // Skip good frames
            if goodFlags[i] {
                i += 1
                continue
            }

            let start = i
            while i < entries.count && !goodFlags[i] {
                i += 1
            }
            let end = i - 1   // inclusive

            /*
             instead of taking the first 'good' homography,
             look a the previous N 'good' homographies within M distance from i
             choose the one with the median deviation among them all
             */
            let leftGood  = bestHomography(
              before: start,
              in: entries,
              checking: 20
            )
            let rightGood = bestHomography(
              after:  i-1,
              in: entries,
              checking: 20
            )

            Log.d("Bad segment \(start)...\(end), leftGood=\(leftGood != nil), rightGood=\(rightGood != nil)")

            // Apply correction strategy
            for idx in start...end {
                let badEntry = entries[idx]
                let badFrame = badEntry.frame
                let neighborFrameIndices = badEntry.neighborFrameIndices

                Log.d("rebuild @ idx \(idx) frame \(badFrame.frameIndex)")

                let newHomography: [AlignmentWarpInfoCodable]?

                switch (leftGood, rightGood) {

                    // 4a️ Only left side good → flat copy
                case (let lg?, nil):
                    newHomography = retargetNeighborHomography(
                      from: lg,
                      toFrameIndex: badFrame.frameIndex,
                      targetNeighborFrameIndices: neighborFrameIndices
                    )

                    // 4b️ Only right side good → flat copy
                case (nil, let rg?):
                    newHomography = retargetNeighborHomography(
                      from: rg,
                      toFrameIndex: badFrame.frameIndex,
                      targetNeighborFrameIndices: neighborFrameIndices
                    )

                    // 4c️ Both sides good → interpolate
                case (let lg?, let rg?):
                    let alpha = Double(idx - start + 1) /
                      Double(end - start + 2)

                    newHomography = interpolateHomography(
                      lg, rg,
                      toFrameIndex: badFrame.frameIndex,
                      targetNeighborFrameIndices: neighborFrameIndices,
                      alpha: alpha
                    )

                default:
                    newHomography = nil
                }
                if let newHomography {
                    let results = HomographyResultsCodable(
                        for: badFrame.frameIndex,
                        with: newHomography
                    )
                    entries[idx].homography = results
                    Log.d("frame \(badFrame.frameIndex) is getting newHomography \(newHomography)")
                    await badFrame.set(
                      neighborStarHomography: results
                    )
                }
            }
        }

        /* 
           XXX smoothing code disabled for now
           
        Log.d("validateMovingStarAlignment applying smoothing")
        
        // apply smoothing
        let V: Double = 0.3 // max allowed divergance of compositeDeviation between frames

        // Smooth deviations
        let original = homographies.map { $0.compositeDeviation }
        let smoothed = smoothDeviations(original, perFrameVariance: V)

        // Adjust only frames that violate constraints
        let epsilon: Double = config.homographySmoothingEpsilon
        let maxScale = 1.25

        for i in 0..<homographies.count {
            let o = original[i]
            let s = smoothed[i]

            guard abs(s - o) > epsilon, o > 0 else {
                Log.d("frame \(i) not smoothing homography o \(o) s \(s) abs(s - o) \(abs(s - o)) epsilon \(epsilon)") 
                continue
            }

            let scale = min(maxScale, max(0.0, s / o))

            Log.d("frame \(i) smoothing homography o \(o) s \(s) abs(s - o) \(abs(s - o)) epsilon \(epsilon) scale \(scale)") 
            
            let adjusted = homographies[i].neighborHomography.map { neighbor in
                guard let h = neighbor.homography else { return neighbor }
                return AlignmentWarpInfoCodable(
                  homography: scaleHomographyTowardsIdentity(h, scale: scale),
                  alignmentState: .homographySuccess,
                  frameIndex: neighbor.frameIndex
                )
            }

            await frames[i].set(
              neighborStarHomography: HomographyResultsCodable(
                for: homographies[i].frameIndex,
                with: adjusted
              )
            )
        }
         */

        Log.d("validateMovingStarAlignment done")
    }
}

func scaleHomographyTowardsIdentity(
    _ h: [Double],
    scale: Double
) -> [Double] {
    let I: [Double] = [
        1,0,0,
        0,1,0,
        0,0,1
    ]

    return zip(h, I).map { hval, Ival in
        Ival + scale * (hval - Ival)
    }
}

func smoothDeviations(
    _ d: [Double],
    perFrameVariance V: Double
) -> [Double] {
    var out = d
    limitForward(&out, maxSlope: V)
    limitBackward(&out, maxSlope: V)
    return out
}

func limitForward(_ d: inout [Double], maxSlope: Double) {
    for i in 1..<d.count {
        let maxAllowed = d[i-1] + maxSlope
        if d[i] > maxAllowed {
            d[i] = maxAllowed
        }
    }
}

func limitBackward(_ d: inout [Double], maxSlope: Double) {
    for i in stride(from: d.count - 2, through: 0, by: -1) {
        let maxAllowed = d[i+1] + maxSlope
        if d[i] > maxAllowed {
            d[i] = maxAllowed
        }
    }
}


/// One slot of the gap-fill table: a frame, the homography we currently have
/// for it (may be nil if alignment failed), and that frame's known neighbor
/// frame indices.  Entries are kept parallel to the validator's `frames`
/// array, so an array index here always lines up with the same array index
/// in `frames` — but never with a frame index.
struct GapFillEntry {
    let frame: FrameAirplaneRemover
    var homography: HomographyResultsCodable?
    let neighborFrameIndices: [Int]
}

func bestHomography(
  before index: Int,
  in entries: [GapFillEntry],
  checking checkCount: Int = 20
) -> HomographyResultsCodable? {
    if index <= 0 { return nil }
    let startIndex = index > checkCount ? index - checkCount : 0
    var homographyBasket: [HomographyResultsCodable] = []
    for i in startIndex..<index {
        if let h = entries[i].homography, h.alignmentLooksOk {
            homographyBasket.append(h)
        }
    }
    return bestMedianHomography(in: homographyBasket)
}

func bestHomography(
  after index: Int,
  in entries: [GapFillEntry],
  checking checkCount: Int = 20
) -> HomographyResultsCodable? {
    if index >= entries.count { return nil }
    let startIndex = index+1
    let endIndex = index + checkCount < entries.count ? index + checkCount : entries.count
    var homographyBasket: [HomographyResultsCodable] = []
    for i in startIndex..<endIndex {
        if let h = entries[i].homography, h.alignmentLooksOk {
            homographyBasket.append(h)
        }
    }
    return bestMedianHomography(in: homographyBasket)
}

/// Copy `src`'s homography values onto a new neighbor list for the target
/// frame, pairing entries by **offset** (`neighbor.frameIndex −
/// selfFrameIndex`).  An entry from `src` at offset −2 becomes an entry on
/// the target at offset −2 (i.e. target's neighbor at `targetFrameIndex −
/// 2`), and so on.  Pairing by offset means asymmetric neighbor lists (e.g.
/// edge frames with fewer neighbors, or alignments where some neighbors
/// failed) can't drift into each other's slots — which would produce a
/// uniform-translation artifact in the rendered output.  Offsets present
/// on the source but missing from the target's expected neighbor list are
/// dropped.
func retargetNeighborHomography(
    from src: HomographyResultsCodable,
    toFrameIndex targetFrameIndex: Int,
    targetNeighborFrameIndices: [Int]
) -> [AlignmentWarpInfoCodable] {
    let validTargets = Set(targetNeighborFrameIndices)
    var ret: [AlignmentWarpInfoCodable] = []
    for entry in src.neighborHomography {
        let offset = entry.frameIndex - src.frameIndex
        let targetNeighbor = targetFrameIndex + offset
        guard validTargets.contains(targetNeighbor) else { continue }
        ret.append(
          AlignmentWarpInfoCodable(
            homography: entry.homography,
            deviation: entry.deviation,
            alignmentState: .homographySuccess,
            frameIndex: targetNeighbor
          )
        )
    }
    return ret.sorted { $0.frameIndex < $1.frameIndex }
}

// returns the best median homography sorted by composite deviation from identity
func bestMedianHomography(
  in homographies: [HomographyResultsCodable]
) -> HomographyResultsCodable? {
    if homographies.count == 0 { return nil }

    let sorted = homographies.sorted() { $0.compositeDeviation < $1.compositeDeviation }

    return sorted[sorted.count/2]
}

func isGood(_ r: HomographyResultsCodable) -> Bool {
    r.alignmentLooksOk &&
    r.neighborHomography.contains { $0.alignmentState == .homographySuccess }
}


/// Interpolate two homography sets onto a third (target) frame, pairing
/// entries by **offset** (`neighbor.frameIndex − selfFrameIndex`).  For each
/// expected neighbor of the target frame we look up the same offset in
/// `w0` and `w1`; if both have an entry, we interpolate the homography
/// matrices and stamp the result on the target's neighbor frame index.  An
/// offset missing from either side is dropped — better to omit a neighbor
/// than to mis-pair it and emit a homography for the wrong relative
/// distance.
func interpolateHomography(
  _ w0: HomographyResultsCodable,
  _ w1: HomographyResultsCodable,
  toFrameIndex targetFrameIndex: Int,
  targetNeighborFrameIndices: [Int],
  alpha: Double
) -> [AlignmentWarpInfoCodable] {
    var w0ByOffset: [Int: AlignmentWarpInfoCodable] = [:]
    for entry in w0.neighborHomography {
        w0ByOffset[entry.frameIndex - w0.frameIndex] = entry
    }
    var w1ByOffset: [Int: AlignmentWarpInfoCodable] = [:]
    for entry in w1.neighborHomography {
        w1ByOffset[entry.frameIndex - w1.frameIndex] = entry
    }

    var ret: [AlignmentWarpInfoCodable] = []
    for targetNeighborFrameIndex in targetNeighborFrameIndices.sorted() {
        let offset = targetNeighborFrameIndex - targetFrameIndex
        guard let w0Entry = w0ByOffset[offset],
              let w1Entry = w1ByOffset[offset],
              let w0H = w0Entry.homography,
              let w1H = w1Entry.homography
        else { continue }
        ret.append(
          AlignmentWarpInfoCodable(
            homography: interpolateHomography(w0H, w1H, alpha: alpha),
            alignmentState: .homographySuccess,
            frameIndex: targetNeighborFrameIndex
          )
        )
    }
    return ret
}

// interpolate linearly between two homographies with given alpha 
func interpolateHomography(
  _ h0: [Double],
  _ h1: [Double],
  alpha: Double
) -> [Double] {
      zip(h0,h1).map { (1.0 - alpha) * $0 + alpha * $1 }
}
