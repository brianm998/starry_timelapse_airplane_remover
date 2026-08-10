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
        Log.d("found \(homographies.count) neighbor homography groups")

        guard let median = medianHomography(among: homographies) else {
            Log.e("ERROR, canceling no homographies found")
            errorClosure("no homographies found")
            self.cancel()
            // have this abort the operation
            return
        }
        Log.d("found median homography at frameIndex \(median.frameIndex) " +
              "with \(median.total) neighbors")

        let config = await configManager.config()

        // apply the chosen median homography to all frames
        for frame in frames {
            // only if this frame has the standard number of neighbor frames
            // ignore ones which have been set differently
            if !config.overriddenNeighborCount(for: frame.frameIndex) {
                // Rebuild the set around *this* frame's own neighbor list instead of
                // copying the median frame's.  Shifting every neighbor index by a
                // constant, which is what this used to do, keeps the source's count and
                // offset shape, and the source can legitimately have a truncated shape:
                // with numberAlignedNeighborFrames = 8, frame 0 of a 19 frame sequence
                // has 4 neighbors and frame 17 has 5, so a median landing on an end frame
                // handed every interior frame a 5 offset set.  The merge looks its
                // homography up by offset (ia_align_and_median_merge), so the three
                // missing offsets silently dropped three of that frame's eight sources.
                let neighborFrameIndices = await frame.getAlignmentFrameIndices()
                await frame.set(
                  neighborStarHomography:
                    HomographyResultsCodable(
                      for: frame.frameIndex,
                      with: extrapolateNeighborHomography(
                        from: median,
                        toFrameIndex: frame.frameIndex,
                        targetNeighborFrameIndices: neighborFrameIndices
                      )
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

/// Pick the median-composite-deviation set to use as the model for a static sequence,
/// considering only the candidates that measured the most neighbors.
///
/// `FrameAlignmentProcessor.calculateNeighborIndices` legitimately gives frames near
/// the ends of the sequence fewer neighbors than interior ones — with the default
/// `numberAlignedNeighborFrames` of 8, frame 0 of a 19 frame sequence gets 4 and frame
/// 17 gets 5 — so candidate sets differ in count.  The winner becomes the model for the
/// whole sequence, and offsets it never measured can only be filled by extrapolation,
/// so a truncated winner would degrade every interior frame.  Restricting to the widest
/// shape costs almost nothing when interior frames are present (11 of the 19 qualify in
/// the example above) and still returns the widest available shape on sequences too
/// short for any frame to have a full set.
///
/// Ties on count are broken exactly as before: sort by composite deviation and take the
/// middle element.
func medianHomography(
  among homographies: [HomographyResultsCodable]
) -> HomographyResultsCodable? {
    // Count the offsets that can actually be reused, not the entries: an entry with no
    // matrix is no wider a shape than a missing one.  `alignmentLooksOk` has already
    // rejected any set holding one, so in practice this equals `total`.
    func usableOffsets(_ results: HomographyResultsCodable) -> Int {
        results.neighborHomography.lazy.filter { $0.homography != nil }.count
    }
    guard let widest = homographies.map(usableOffsets).max() else { return nil }
    let fullShape = homographies.filter { usableOffsets($0) == widest }
    let sorted = fullShape.sorted { $0.compositeDeviation < $1.compositeDeviation }
    return sorted[sorted.count/2]
}

/// Copy `src`'s homography onto `targetFrameIndex`, pairing entries by **offset**
/// (`neighbor.frameIndex − selfFrameIndex`) against the offsets the target frame
/// actually has.  Offsets present on `src` but not on the target are dropped, and
/// offsets the target has but `src` lacks are filled from a linear model of `src`
/// (see `HomographyOffsetModel`).
///
/// This is what keeps the target frame's neighbor count independent of `src`'s.  Shifting
/// every neighbor index by a constant, which is how this used to be done, preserves the
/// source's count and offset shape instead, and that silently truncated every frame in
/// the sequence whenever the chosen source was an end frame.
///
/// Unlike `retargetNeighborHomography`, which only drops, this fills — appropriate on a
/// static tripod, where the warp to a neighbor `d` frames away is a function of `d`
/// alone.
func extrapolateNeighborHomography(
    from src: HomographyResultsCodable,
    toFrameIndex targetFrameIndex: Int,
    targetNeighborFrameIndices: [Int]
) -> [AlignmentWarpInfoCodable] {
    var srcByOffset: [Int: AlignmentWarpInfoCodable] = [:]
    for entry in src.neighborHomography {
        srcByOffset[entry.frameIndex - src.frameIndex] = entry
    }
    let model = HomographyOffsetModel(from: src)

    var ret: [AlignmentWarpInfoCodable] = []
    for targetNeighborFrameIndex in targetNeighborFrameIndices.sorted() {
        let offset = targetNeighborFrameIndex - targetFrameIndex
        if offset == 0 { continue }     // a frame is never its own neighbor
        // An entry the source has but could not solve counts as unmeasured: copying its
        // failure onto this frame would state something about this frame's alignment
        // that was never tested, and the model can cover the offset instead.  Candidates
        // reaching here have passed alignmentLooksOk, which already rejects a set with
        // any unsolved neighbor, so this is a guard rather than a common path.
        if let entry = srcByOffset[offset],
           entry.homography != nil
        {
            ret.append(
              AlignmentWarpInfoCodable(
                homography: entry.homography,
                deviation: entry.deviation,
                alignmentState: entry.alignmentState,
                frameIndex: targetNeighborFrameIndex
              )
            )
        } else if let model {
            ret.append(
              AlignmentWarpInfoCodable(
                homography: model.homography(atOffset: offset),
                // not measured for any frame at this distance, derived from the ones
                // that were — flagged so the gui and the horizon tuner can tell
                alignmentState: .usedExistingHomography,
                frameIndex: targetNeighborFrameIndex
              )
            )
        }
    }
    return ret
}

/// A linear model of how a static sequence's neighbor homography varies with frame
/// offset, used to fill an offset the source set never measured.
///
/// On a static tripod the sky rotates at a constant rate, so the warp between a frame
/// and its neighbor `d` frames away is a function of `d` alone, and is exactly identity
/// at `d == 0`.  Each of the 9 matrix elements is fit as `h(d) = I + slope·d` by least
/// squares through that origin over whatever offsets the source did measure.  For a
/// rotation of angle θ·d the translation and off-diagonal terms are linear in `d` and
/// the diagonal stays ≈1, so this is first-order accurate at the small per-frame angles
/// of a timelapse.
///
/// Only reached on sequences too short for any frame to have a full neighbor set, since
/// `medianHomography(among:)` otherwise picks a source whose shape already covers every
/// interior frame's offsets.
struct HomographyOffsetModel {
    private static let identity: [Double] = [
      1, 0, 0,
      0, 1, 0,
      0, 0, 1
    ]

    /// per-element rate of change with respect to frame offset
    private let slope: [Double]

    /// nil when `results` holds no usable homography to fit
    init?(from results: HomographyResultsCodable) {
        var weightedSum = [Double](repeating: 0, count: 9)
        var offsetSquares: Double = 0
        for entry in results.neighborHomography {
            guard let h = entry.homography,
                  h.count == Self.identity.count
            else { continue }
            let offset = Double(entry.frameIndex - results.frameIndex)
            if offset == 0 { continue }
            for i in 0..<h.count {
                weightedSum[i] += offset * (h[i] - Self.identity[i])
            }
            offsetSquares += offset * offset
        }
        guard offsetSquares > 0 else { return nil }
        self.slope = weightedSum.map { $0 / offsetSquares }
    }

    func homography(atOffset offset: Int) -> [Double] {
        let distance = Double(offset)
        return zip(Self.identity, slope).map { $0 + $1 * distance }
    }
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
