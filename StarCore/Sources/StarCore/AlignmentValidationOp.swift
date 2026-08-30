import Foundation
import StarCppBridge
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
            // Only the moving case has an earth homography to validate: a stationary
            // tripod's ground needs no warp, so FrameGraphBuilder computes none — see
            // `processEarth` there.
            if config.allowEarthAlignment, config.tripodHeadWasMoving {
                await validateMovingEarthAlignment()
            }
        } catch {
            let str = "error during alignment validation: \(error)"
            Log.e(str)
            errorClosure(str)
        }
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

        // One median per offset assumes every consecutive gap is one nominal step of
        // time.  Measure the gaps that were not — a ramped interval settling at dusk,
        // a stalled buffer — so the pairs spanning them get a warp scaled to the time
        // that actually passed instead of a full step's worth.  Empty on the sequences
        // the assumption holds for, which keeps the stamped entries bit-identical there.
        let anomalousGaps = await measureCaptureGapAnomalies(median: median, config: config)

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
                      with: cadenceAwareNeighborHomography(
                        from: median,
                        toFrameIndex: frame.frameIndex,
                        targetNeighborFrameIndices: neighborFrameIndices,
                        anomalousGaps: anomalousGaps
                      )
                    )
                )
            }
        }
        Log.d("done validating static star alignment")
    }

    /// The consecutive capture gaps whose measured duration is not one nominal step:
    /// lower frame index of the gap → its duration in steps.  Empty when every gap
    /// is nominal, which is the common case and leaves the stamping path untouched.
    ///
    /// Keypoint-position matching decides most gaps for free; the ones it cannot —
    /// twilight frames where the strongest keypoints sit on clouds and fixed-pattern
    /// sensor content, and any gap genuinely shorter than a third of a step — are
    /// measured from the original images by phase correlation.
    private func measureCaptureGapAnomalies(
      median: HomographyResultsCodable,
      config: Config
    ) async -> [Int: Double] {
        let sorted = frames.sorted { $0.frameIndex < $1.frameIndex }
        guard sorted.count >= 2 else { return [:] }

        // the model of one nominal step: the median's +1 entry, or the inverse of
        // its -1 entry when the median frame had no later neighbour
        var oneStep: [Double]? = nil
        for entry in median.neighborHomography {
            guard let h = entry.homography else { continue }
            let offset = entry.frameIndex - median.frameIndex
            if offset == 1 { oneStep = h; break }
            if offset == -1, oneStep == nil { oneStep = CaptureCadence.invert3x3(h) }
        }
        guard let oneStep else {
            Log.w("static cadence check skipped: the median homography set has " +
                  "no one-step entry to model a nominal gap with")
            return [:]
        }

        // Tier 1: keypoint positions, loaded concurrently.  Deliberately not through
        // keypointCache, which pins entries for the run — the positions are a few
        // hundred KB where the cached feature sets are megabytes of descriptors.
        let loadStart = Date()
        var positions: [Int: [(x: Double, y: Double)]] = [:]
        await withTaskGroup(of: (Int, [(x: Double, y: Double)])?.self) { taskGroup in
            var inFlight = 0
            for frame in sorted {
                let frameIndex = frame.frameIndex
                guard let path = config.keypointPath(frameIndex: frameIndex,
                                                     ofType: .starAligned)
                else { continue }
                if inFlight >= 8, let result = await taskGroup.next() {
                    if let (index, points) = result { positions[index] = points }
                    inFlight -= 1
                }
                taskGroup.addTask {
                    guard let features = OCVFeatureSet.load(fromFilename: path)
                    else { return nil }
                    return (frameIndex, features.keypointPositions())
                }
                inFlight += 1
            }
            for await result in taskGroup {
                if let (index, points) = result { positions[index] = points }
            }
        }

        Log.i("static cadence check: loaded keypoint positions for " +
              "\(positions.count) frames in " +
              "\(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

        var spans: [Int: Double] = [:]
        var undecided: [Int] = []
        for (frame, next) in zip(sorted, sorted.dropFirst()) {
            guard next.frameIndex == frame.frameIndex + 1 else { continue }
            let gap = frame.frameIndex
            if let earlier = positions[gap],
               let later = positions[gap + 1],
               let span = CaptureCadence.trustedSpan(
                 CaptureCadence.matchedStarSpan(from: earlier,
                                                to: later,
                                                oneStep: oneStep))
            {
                spans[gap] = span
            } else {
                undecided.append(gap)
            }
        }

        // Tier 2: the images themselves, for the gaps keypoints could not decide.
        // Bounded: a sequence with no usable stars anywhere would otherwise decode
        // every frame twice here for answers it cannot give.
        let tier2Limit = 64
        if undecided.count > tier2Limit {
            Log.w("static cadence check: \(undecided.count) gaps have no keypoint " +
                  "answer, measuring the first \(tier2Limit) from the images and " +
                  "treating the rest as nominal")
        }
        if !undecided.isEmpty {
            let framesByIndex = Dictionary(uniqueKeysWithValues:
                                             sorted.map { ($0.frameIndex, $0) })
            let crops = await skyCrops(for: sorted[0])

            // originals seen by this pass, kept only as long as a nearby gap can
            // still want them
            var images: [Int: PixelatedImage] = [:]
            func image(_ index: Int) async -> PixelatedImage? {
                if let held = images[index] { return held }
                guard let frame = framesByIndex[index] else { return nil }
                guard let loaded = try? await frame.imageAccessor.load(
                        frameIndex: index, type: .original, atSize: .original)
                else { return nil }
                images[index] = loaded
                return loaded
            }

            let toMeasure = undecided.sorted().prefix(tier2Limit)
            for gap in toMeasure {
                for held in images.keys where held < gap - 2 {
                    images.removeValue(forKey: held)
                }
                guard let earlier = await image(gap),
                      let later = await image(gap + 1)
                else { continue }
                if let span = CaptureCadence.consensusSpan(
                     from: earlier, to: later, oneStep: oneStep, crops: crops)
                {
                    spans[gap] = span
                }
            }

            // Tier 2b: the leftovers, measured over a longer baseline.  Clouds
            // deform and decorrelate over a few frames while the stars stay
            // identical, so a pair a few steps apart is more star-dominated than
            // the gap's own pair — the gap's duration is the baseline's measured
            // span minus its other, already-decided gaps.  Two baselines have to
            // agree before the answer is believed.
            let leftover = toMeasure.filter { spans[$0] == nil }
            for gap in leftover {
                for held in images.keys where held < gap - 2 {
                    images.removeValue(forKey: held)
                }
                var estimates: [Double] = []
                for (a, b) in [(gap - 1, gap + 1), (gap, gap + 2),
                               (gap - 2, gap + 1), (gap, gap + 3)] {
                    guard framesByIndex[a] != nil, framesByIndex[b] != nil
                    else { continue }
                    var known = 0.0
                    var allDecided = true
                    for other in a..<b where other != gap {
                        if let span = spans[other] {
                            known += span
                        } else {
                            allDecided = false
                            break
                        }
                    }
                    guard allDecided,
                          let earlier = await image(a),
                          let later = await image(b),
                          let total = CaptureCadence.consensusSpan(
                            from: earlier, to: later, oneStep: oneStep, crops: crops)
                    else { continue }
                    let estimate = total - known
                    guard estimate > -0.05, estimate < 4.0 else { continue }
                    estimates.append(max(0.0, estimate))
                    if estimates.count >= 2 { break }
                }
                if estimates.count >= 2, abs(estimates[0] - estimates[1]) <= 0.25 {
                    spans[gap] = (estimates[0] + estimates[1]) / 2
                }
            }
        }

        let anomalies = spans.filter {
            abs($0.value - 1.0) > CaptureCadence.anomalyTolerance
        }
        if anomalies.isEmpty {
            Log.i("static cadence check: \(spans.count) of \(sorted.count - 1) " +
                  "gaps measured, all nominal")
        } else {
            for (gap, span) in anomalies.sorted(by: { $0.key < $1.key }) {
                Log.i("static cadence check: the capture gap between frames " +
                      "\(gap) and \(gap + 1) measures \(String(format: "%.2f", span)) " +
                      "of the nominal interval — pairs spanning it get a warp " +
                      "scaled to match")
            }
        }
        return anomalies
    }

    /// Squares of sky to phase-correlate, spread across the frame's width and kept
    /// in the *upper* sky.  Up there twilight leaves the stars alone; the band just
    /// above the horizon is where the dusk glow and the clouds live, and a crop
    /// placed there is what let fixed-pattern content win the correlation.  Several
    /// crops rather than one because `CaptureCadence.consensusSpan` only believes
    /// answers that agree across them.
    private func skyCrops(for frame: FrameAirplaneRemover) async -> [(x: Int, y: Int, size: Int)] {
        let width = frame.width
        let height = frame.height
        var skyBottom = Int(Double(height) * 0.45)
        if let mask = try? await frame.loadOrCreateFinalHorizonMask() {
            // the smaller of the two bounds is the highest ground anywhere
            let top = min(mask.horizonTopY, mask.horizonBottomY)
            if top > height / 4 { skyBottom = top - 200 }
        }
        let y = max(0, (skyBottom * 3) / 20)
        var size = 1600
        size = min(size, (skyBottom * 9) / 20, width / 3 - 8)
        size = max(size, 64)
        return [width / 6, width / 2, (5 * width) / 6].map { centerX in
            (x: max(0, min(centerX - size / 2, width - size - 1)),
             y: min(y, height - size - 1),
             size: size)
        }
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

    // MARK: - Earth

    /// Replace the ground homographies that jumped.
    ///
    /// A moving tripod's ground warp drifts; it does not jump.  There is no
    /// sequence-wide model for it the way there is for a static tripod's sky — where
    /// the head goes next is up to whoever is turning it — but the head's motion
    /// changes slowly compared with the frame interval, so for a fixed neighbour offset
    /// `d` the warp between a frame and its neighbour traces a smooth curve as the
    /// sequence advances.  A frame that leaves that curve has an estimation failure,
    /// not a real move.
    ///
    /// Those failures are common on the ground and rare in the sky, and for a reason
    /// that is not going to go away: a dark foreground offers far fewer and far weaker
    /// features than a sky full of stars, and they sit in a thin band across the bottom
    /// of the frame, which is a poorly conditioned set of points to fit eight degrees
    /// of freedom to.  Measured on 31 frames of a 33MP aurora sequence at 8 neighbours
    /// each: the frame-to-frame change in where the ground warp lands a point had a
    /// median of 1.4 to 4.3px near the frame centre but 7 to 62px at the left and right
    /// edges of the ground, and individual entries were wrong by as much as 62px —
    /// including one whose sign was inverted.  Every one of those is a source in the
    /// ground median merge, so each bad entry smears the ground it was meant to clean.
    ///
    /// So each entry is compared against a robust local model of the same offset in
    /// nearby frames and replaced when it disagrees.  Per offset, not per frame: the
    /// warp to the neighbour 4 frames back is a different quantity from the warp to the
    /// one 1 frame forward, and only entries measuring the same thing belong in the
    /// same median.
    func validateMovingEarthAlignment() async {
        var entries: [GapFillEntry] = []
        for frame in frames {
            entries.append(
              GapFillEntry(
                frame: frame,
                homography: await frame.getNeighborEarthHomography(),
                neighborFrameIndices: await frame.getAlignmentFrameIndices()
              )
            )
        }
        guard let firstFrame = frames.first else { return }

        let coverage = GroundTrackingCoverage(frames: entries.map {
            GroundTrackingCoverage.Frame(neighborFrameIndices: $0.neighborFrameIndices,
                                         homography: $0.homography)
        })
        Log.i("validateMovingEarthAlignment: \(coverage.solvedPairs) of " +
              "\(coverage.expectedPairs) neighbour pairs have a measured ground " +
              "homography (\(String(format: "%.1f", coverage.solvedFraction * 100))%)")

        // A ground that cannot be tracked is not an error — the merge falls back to
        // each frame's own pixels, which is what earth alignment off does — but it is
        // not what was asked for either, and the output looks like nothing happened.
        // Say so once, with the reason: this is what a foreground with no detail in it
        // produces, and the usual cause is source frames whose shadows were clipped to
        // black before star saw them.
        //
        // A `StarWarning` rather than the `Log.w` this used to be, because the log it
        // was written to is ~/Library/Logs/star and nobody reads it — least of all the
        // user whose finished ground still has whatever crossed it in.  `StarWarnings`
        // logs at the same level on its way past, so nothing is lost by going through
        // it, and the gui banner and the desktop client's notification are gained.
        //
        // `.warning`, not `.critical`: the run finishes and everything above the
        // horizon is exactly as good as it would have been.
        if coverage.groundWasNotTracked {
            await StarWarnings.shared.post(StarWarning(
              kind: .groundAlignmentFailed,
              severity: .warning,
              message: localized("warning.ground_alignment_failed.message",
                                 coverage.failedPairs, coverage.expectedPairs),
              suggestion: localized("warning.ground_alignment_failed.suggestion")
            ))
        }

        guard coverage.solvedPairs > 0 else {
            // Not fatal the way it is for the sky.  With no ground homography at all
            // every frame falls back to its own unwarped pixels, which is what the
            // pipeline does with earth alignment off — a worse result than was asked
            // for, not a broken one.
            Log.w("validateMovingEarthAlignment: no ground homographies to validate")
            return
        }

        // frameIndex -> offset -> matrix, for the offsets that were actually solved,
        // and frameIndex -> the offsets that frame is supposed to have.  Near the ends
        // of a sequence a frame legitimately has fewer neighbours, and filling in one
        // it never had would hand the merge a source that does not exist.
        var measuredByFrame: [Int: [Int: [Double]]] = [:]
        var expectedOffsets: [Int: [Int]] = [:]
        for entry in entries {
            let frameIndex = entry.frame.frameIndex
            expectedOffsets[frameIndex] = entry.neighborFrameIndices.map { $0 - frameIndex }
            guard let results = entry.homography else { continue }
            var byOffset: [Int: [Double]] = [:]
            for warp in results.neighborHomography {
                guard let h = warp.homography, h.count == 9 else { continue }
                byOffset[warp.frameIndex - results.frameIndex] = h
            }
            measuredByFrame[frameIndex] = byOffset
        }

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measuredByFrame,
          expectedOffsets: expectedOffsets,
          probes: EarthHomographyContinuityFilter.groundProbePoints(
            width: firstFrame.width, height: firstFrame.height
          )
        )

        for report in result.perOffset {
            Log.i("validateMovingEarthAlignment offset \(report.offset): " +
                  "\(report.comparableFrames) comparable frames, median disagreement " +
                  "\(String(format: "%.2f", report.medianDisagreement))px, worst " +
                  "\(String(format: "%.2f", report.worstDisagreement))px, cutoff " +
                  "\(String(format: "%.2f", report.cutoff))px, " +
                  "\(report.replaced) replaced, \(report.filled) filled")
        }

        guard result.replaced + result.filled > 0 else {
            Log.i("validateMovingEarthAlignment: every ground homography agrees with " +
                  "its neighbours, nothing to correct")
            return
        }

        // Write back only the frames that changed.
        for entry in entries {
            let frameIndex = entry.frame.frameIndex
            guard let corrections = result.corrected[frameIndex],
                  !corrections.isEmpty
            else { continue }
            var byOffset: [Int: AlignmentWarpInfoCodable] = [:]
            for warp in entry.homography?.neighborHomography ?? [] {
                byOffset[warp.frameIndex - frameIndex] = warp
            }
            for (offset, newHomography) in corrections {
                byOffset[offset] = AlignmentWarpInfoCodable(
                  homography: newHomography,
                  deviation: homographyDeviation(newHomography),
                  // Not what this frame measured: taken from the frames around it
                  // because what it measured did not agree with them.  The same state
                  // the static path uses when it fills an offset from a model.
                  alignmentState: .usedExistingHomography,
                  frameIndex: frameIndex + offset
                )
            }
            await entry.frame.set(
              neighborEarthHomography: HomographyResultsCodable(
                for: frameIndex,
                with: byOffset.values.sorted { $0.frameIndex < $1.frameIndex }
              )
            )
        }

        Log.i("validateMovingEarthAlignment: replaced \(result.replaced) ground " +
              "homographies that disagreed with their neighbours and filled " +
              "\(result.filled) that were missing")
    }
}


/// How much of a moving sequence's ground actually got measured, and whether that is
/// little enough to be worth telling the user about.
///
/// Counted per neighbour pair, not per frame.  A frame has a results container as soon as
/// its homography op ran, whether or not any of the warps inside it were solved, so
/// counting containers reports a fully-measured sequence for one where every single pair
/// was rejected — which is precisely the case worth noticing.
///
/// Split out of `validateMovingEarthAlignment` so the threshold can be exercised without
/// standing up a sequence of real frames: `GapFillEntry` carries a whole
/// `FrameAirplaneRemover`, and none of that is involved in the count.
struct GroundTrackingCoverage {

    /// One frame's contribution — the two fields of `GapFillEntry` the count reads.
    struct Frame {
        /// The neighbours this frame is supposed to have.  Frames near the ends of a
        /// sequence legitimately have fewer, so the expected total is not frame count
        /// times neighbour count.
        let neighborFrameIndices: [Int]

        /// What its homography op produced, if it ran at all.
        let homography: HomographyResultsCodable?

        init(neighborFrameIndices: [Int], homography: HomographyResultsCodable?) {
            self.neighborFrameIndices = neighborFrameIndices
            self.homography = homography
        }
    }

    /// The share of pairs that has to have solved before the ground counts as tracked.
    ///
    /// Ground estimation failing on individual pairs is ordinary — a dark foreground is a
    /// poorly conditioned thing to fit eight degrees of freedom to, which is the whole
    /// reason `EarthHomographyContinuityFilter` exists — and a handful of fills changes
    /// nothing anyone would see.  Below half there is no longer a solid enough local
    /// model left for that filter to fill the gaps from, and the frames it cannot fill
    /// merge their ground unwarped.
    static let minimumSolvedFraction: Double = 0.5

    /// Every neighbour pair the sequence is supposed to have, summed over its frames.
    let expectedPairs: Int

    /// The subset of those that produced a matrix the frame can actually use.
    let solvedPairs: Int

    init(frames: [Frame]) {
        var solved = 0
        var expected = 0
        for frame in frames {
            expected += frame.neighborFrameIndices.count

            // Only the warps that landed on a neighbour this frame still has.  A stored
            // container outlives the setting that shaped it: re-run a sequence with a
            // smaller `numberAlignedNeighborFrames` and the entries from the wider run
            // are still on disk, at neighbour indices this frame no longer has.  The
            // merge looks its homography up by offset and never asks for those, so
            // counting them measures coverage the run cannot spend — and it inflates the
            // count in the one direction that matters, suppressing the warning on a
            // sequence whose usable pairs are actually below the threshold.
            //
            // As sets, so the count cannot exceed the frame's own neighbour count no
            // matter what a container holds, and `solvedFraction` therefore cannot come
            // out above 1.
            let wanted = Set(frame.neighborFrameIndices)
            let solvedNeighbours = Set(
              (frame.homography?.neighborHomography ?? [])
                .lazy.filter { $0.homography != nil }.map(\.frameIndex)
            )
            solved += solvedNeighbours.intersection(wanted).count
        }
        self.expectedPairs = expected
        self.solvedPairs = solved
    }

    var failedPairs: Int { expectedPairs - solvedPairs }

    /// Zero rather than a division by zero on a sequence with no neighbours at all.
    var solvedFraction: Double {
        expectedPairs > 0 ? Double(solvedPairs) / Double(expectedPairs) : 0
    }

    /// Strictly below the threshold, so a sequence that solved exactly half of its pairs
    /// is left alone — half is still enough for the continuity filter to fill from.
    ///
    /// The `expectedPairs > 0` guard is what stops a sequence with nothing to measure
    /// reporting a fully untracked ground: `solvedFraction` is 0 there for want of a
    /// denominator, not because anything failed.
    var groundWasNotTracked: Bool {
        solvedFraction < Self.minimumSolvedFraction && expectedPairs > 0
    }
}


/// Finds the ground homographies that jumped, and what to put in their place.
///
/// Pure: it sees frame indices and 3x3 matrices, nothing else, so the rule it applies
/// can be exercised directly.  `AlignmentValidationOp.validateMovingEarthAlignment`
/// gathers the input from the frames and writes the answer back.
public enum EarthHomographyContinuityFilter {

    /// How many frames either side of a frame make up the local model of one offset.
    /// Wide enough that a single bad frame cannot dominate the median, narrow enough
    /// that the model still tracks a head that is speeding up or slowing down.
    public static let windowRadius = 4

    /// Below this many samples in the window there is nothing to compare against, and
    /// a frame is left exactly as measured rather than judged on two neighbours.
    public static let minWindowSamples = 3

    /// How far, in pixels, a frame's ground warp may land a point from where the local
    /// model puts it before it is treated as an estimation failure.
    ///
    /// The cutoff is a multiple of the offset's own median disagreement, held between
    /// these two: scaling with the sequence keeps a well-tracked ground on a tight
    /// cutoff and stops a barely-trackable one having most of its frames declared bad,
    /// but neither end of that can be allowed to run away.
    ///
    /// Tuned against phase correlation, which measures how far a piece of ground
    /// actually moved without using any of the keypoint machinery, so it can say
    /// whether a replacement was an improvement.  Over 126 frame pairs of a 33MP
    /// aurora sequence, scoring the error at the centre of each third of the ground
    /// band: leaving everything alone gave worst-case errors of 39.5px (left third),
    /// 11.1px (centre) and 15.4px (right); this policy gives 6.3, 7.6 and 4.8, and
    /// nudges the medians down as well.  A looser 4x/8/20 gave 7.4, 7.6 and 7.5 —
    /// still most of the gain, so the exact numbers are not a knife edge.
    public static let minCutoff: Double = 4
    public static let maxCutoff: Double = 12

    /// Multiple of the median disagreement at which an entry is called an outlier.
    public static let deviationMultiple: Double = 3

    /// What one neighbour offset looked like across the sequence.  Logged, so a run
    /// that corrected a lot says why.
    public struct OffsetReport: Sendable {
        public let offset: Int
        public let comparableFrames: Int
        public let medianDisagreement: Double
        public let worstDisagreement: Double
        public let cutoff: Double
        public let replaced: Int
        public let filled: Int
    }

    public struct Result: Sendable {
        /// frameIndex -> offset -> the matrix to use instead.  Only the entries that
        /// changed; a frame with nothing to correct is absent.
        public let corrected: [Int: [Int: [Double]]]
        /// measured, but too far from its neighbours to believe
        public let replaced: Int
        /// never measured, and filled in from the neighbours
        public let filled: Int
        public let perOffset: [OffsetReport]
    }

    /// - Parameters:
    ///   - measured: frameIndex -> offset -> row-major 3x3, for the offsets that were
    ///     solved.  An offset that failed is simply absent.
    ///   - expectedOffsets: frameIndex -> the offsets that frame is supposed to have.
    ///     Frames near the ends of a sequence legitimately have fewer neighbours, and
    ///     filling in one a frame never had would hand the merge a source that does
    ///     not exist.
    ///   - probes: image points at which two homographies are compared.
    public static func corrections(
      measured: [Int: [Int: [Double]]],
      expectedOffsets: [Int: [Int]],
      probes: [(x: Double, y: Double)]
    ) -> Result {
        var corrected: [Int: [Int: [Double]]] = [:]
        var reports: [OffsetReport] = []
        var replacedTotal = 0
        var filledTotal = 0

        let offsets = Set(measured.values.flatMap { $0.keys }).sorted()

        for offset in offsets {
            // The local model for each frame, and how far that frame's own entry is
            // from it.  Both are computed for every frame before anything is replaced,
            // because the cutoff comes from the spread of those distances and every
            // judgement has to be made against what was measured.
            var localModel: [Int: [Double]] = [:]
            var distance: [Int: Double] = [:]

            for (frameIndex, expected) in expectedOffsets {
                guard expected.contains(offset) else { continue }

                var window: [[Double]] = []
                for other in (frameIndex - windowRadius)...(frameIndex + windowRadius) {
                    guard other != frameIndex,
                          let h = measured[other]?[offset]
                    else { continue }
                    window.append(h)
                }
                guard window.count >= minWindowSamples else { continue }

                let model = medoidHomography(of: window, at: probes)
                localModel[frameIndex] = model
                if let own = measured[frameIndex]?[offset] {
                    distance[frameIndex] = maxProbeDistance(between: own,
                                                            and: model,
                                                            at: probes)
                }
            }

            let sortedDistances = distance.values.sorted()
            let typical = sortedDistances.isEmpty
              ? 0
              : sortedDistances[sortedDistances.count/2]
            let cutoff = min(maxCutoff, max(minCutoff, typical * deviationMultiple))

            var replaced = 0
            var filled = 0
            for (frameIndex, model) in localModel {
                if let d = distance[frameIndex] {
                    guard d > cutoff else { continue }
                    replaced += 1
                } else {
                    // measured for its neighbours but not for this frame
                    filled += 1
                }
                corrected[frameIndex, default: [:]][offset] = model
            }
            replacedTotal += replaced
            filledTotal += filled

            if !sortedDistances.isEmpty {
                reports.append(
                  OffsetReport(offset: offset,
                               comparableFrames: sortedDistances.count,
                               medianDisagreement: typical,
                               worstDisagreement: sortedDistances[sortedDistances.count - 1],
                               cutoff: cutoff,
                               replaced: replaced,
                               filled: filled)
                )
            }
        }

        return Result(corrected: corrected,
                      replaced: replacedTotal,
                      filled: filledTotal,
                      perOffset: reports)
    }

    /// Where two ground warps are compared: the centre of each third of the frame's
    /// width, at two heights near the bottom.
    ///
    /// The ground is by definition below the horizon, so the bottom of the frame is the
    /// part of it every sequence has.  Height matters more than it looks: probing the
    /// bottom quarter reaches above the horizon on a typical landscape frame, and up
    /// there the two warps are both extrapolating into sky neither was fitted to.
    /// Measured on the same 33MP sequence, the median disagreement between a frame's
    /// warp and its neighbours' reads 20.5px probed over the bottom quarter's corners
    /// and 2.7px probed here — the difference is almost entirely sky, and the loose
    /// reading pushed the adaptive cutoff to its ceiling and had a third of the
    /// sequence declared bad.
    ///
    /// Thirds rather than the frame's corners for the same reason in the other axis: at
    /// x = 0 and x = width - 1 there is often no ground content to have constrained the
    /// fit, so the two warps disagree there without either being wrong about anything
    /// the merge will read.
    public static func groundProbePoints(
      width: Int, height: Int
    ) -> [(x: Double, y: Double)] {
        let upper = Double(height) * 0.95
        let lower = Double(height - 1)
        let w = Double(width)
        return [w/6, w/2, 5*w/6]
          .flatMap { x in [(x: x, y: upper), (x: x, y: lower)] }
    }
}


/// The largest distance, over `probes`, between where two homographies send the same
/// point.  This is what a difference between two ground warps costs the merge, and it
/// is not what `deviation` measures: `norm(H - I)` is dominated by the matrix's
/// translation column, which is where the warp sends the image *origin* — thousands of
/// pixels above the ground on a landscape frame, so a rotation too small to matter down
/// at the horizon shows up there as a huge number.
func maxProbeDistance(
  between a: [Double],
  and b: [Double],
  at probes: [(x: Double, y: Double)]
) -> Double {
    guard a.count == 9, b.count == 9 else { return .infinity }
    var worst: Double = 0
    for probe in probes {
        guard let pa = project(a, probe), let pb = project(b, probe) else { return .infinity }
        worst = max(worst, ((pa.x - pb.x)*(pa.x - pb.x) + (pa.y - pb.y)*(pa.y - pb.y)).squareRoot())
    }
    return worst
}

private func project(
  _ h: [Double],
  _ p: (x: Double, y: Double)
) -> (x: Double, y: Double)? {
    let w = h[6]*p.x + h[7]*p.y + h[8]
    guard abs(w) > 1e-12 else { return nil }
    return ((h[0]*p.x + h[1]*p.y + h[2]) / w,
            (h[3]*p.x + h[4]*p.y + h[5]) / w)
}

/// The member of `homographies` that agrees best with the rest of them.
///
/// A medoid rather than any kind of average, and that is the whole point: the answer is
/// one of the measured warps, so it is guaranteed to be a self-consistent homography
/// that some frame actually observed.
///
/// The obvious alternative, an element-wise median of the nine matrix entries, was
/// built first and measured against this — it is materially worse, and for a reason
/// worth writing down.  A homography's effect is a ratio: the projective row (h6, h7)
/// divides the translation column (h2, h5), and on a ground fit those two are strongly
/// correlated because the points are all in a band at the bottom of the frame.  Taking
/// each entry's median independently pairs one frame's projective row with another
/// frame's translation, breaking that correlation and producing a matrix no frame ever
/// measured, whose behaviour away from the fixed point can be far off both.  Scored
/// against phase correlation over 126 frame pairs, the element-wise median left the
/// worst-case ground error at 12.7 / 14.8 / 26.4px across the three thirds and made
/// three of the five entries it replaced *worse* than they had been (one going from
/// 0.5px to 26.4px); the medoid gives 6.3 / 7.6 / 4.8px and improved every entry it
/// touched.
///
/// The cost is the sum of the closest half of each candidate's distances rather than
/// all of them, so a window holding two or three wild members still elects a good one.
func medoidHomography(
  of homographies: [[Double]],
  at probes: [(x: Double, y: Double)]
) -> [Double] {
    guard homographies.count > 1 else {
        return homographies.first ?? [1,0,0, 0,1,0, 0,0,1]
    }
    var best = homographies[0]
    var bestCost = Double.infinity
    // By index, not by value: two members of a window can legitimately hold the same
    // matrix — one of them may already have been replaced by the other — and `!=` on
    // the arrays would then drop both from the comparison.
    for (candidateIndex, candidate) in homographies.enumerated() {
        var distances: [Double] = []
        for (otherIndex, other) in homographies.enumerated()
          where otherIndex != candidateIndex
        {
            distances.append(maxProbeDistance(between: candidate, and: other, at: probes))
        }
        guard !distances.isEmpty else { continue }
        distances.sort()
        let counted = min(distances.count, distances.count/2 + 1)
        let cost = distances.prefix(counted).reduce(0, +)
        if cost < bestCost { bestCost = cost; best = candidate }
    }
    return best
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

/// `extrapolateNeighborHomography`, made aware of capture gaps that are not one
/// nominal step long.
///
/// A neighbor pair whose span contains no anomalous gap gets exactly what
/// `extrapolateNeighborHomography` gives it — the median's own entry, bit for bit —
/// so sequences with a steady cadence are untouched.  A pair spanning an anomalous
/// gap gets the median warp for the *time* the span actually covers: the sum of its
/// gaps' durations in nominal steps, turned into a matrix by interpolating between
/// the median's own integer-offset entries (`CaptureCadence.fractionalHomography`).
/// Those entries carry `.usedExistingHomography`, the same "derived, not measured"
/// state the extrapolation path uses for offsets it fills from the model.
public func cadenceAwareNeighborHomography(
    from src: HomographyResultsCodable,
    toFrameIndex targetFrameIndex: Int,
    targetNeighborFrameIndices: [Int],
    anomalousGaps: [Int: Double]
) -> [AlignmentWarpInfoCodable] {
    let nominal = extrapolateNeighborHomography(
      from: src,
      toFrameIndex: targetFrameIndex,
      targetNeighborFrameIndices: targetNeighborFrameIndices
    )
    guard !anomalousGaps.isEmpty else { return nominal }

    var anchors: [Int: [Double]] = [:]
    for entry in src.neighborHomography {
        guard let h = entry.homography else { continue }
        anchors[entry.frameIndex - src.frameIndex] = h
    }

    return nominal.map { entry in
        let neighborIndex = entry.frameIndex
        let low = min(targetFrameIndex, neighborIndex)
        let high = max(targetFrameIndex, neighborIndex)
        // the gaps this pair spans, keyed by their lower frame
        var span = 0.0
        var crossesAnomaly = false
        for gap in low..<high {
            if let measured = anomalousGaps[gap] {
                span += measured
                crossesAnomaly = true
            } else {
                span += 1.0
            }
        }
        guard crossesAnomaly else { return entry }
        let signedSpan = neighborIndex > targetFrameIndex ? span : -span
        guard let synthesized = CaptureCadence.fractionalHomography(
                atSpan: signedSpan,
                anchors: anchors
              )
        else { return entry }
        return AlignmentWarpInfoCodable(
          homography: synthesized,
          // derived from the median and the measured gap, not measured for this
          // pair itself — the same state the offset model's fills carry
          alignmentState: .usedExistingHomography,
          frameIndex: neighborIndex
        )
    }
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
