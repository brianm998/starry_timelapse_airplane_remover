import XCTest
@testable import StarCore

/// Tests for `EarthHomographyContinuityFilter`, the rule that decides which of a moving
/// sequence's ground homographies to throw away.
///
/// What it exists for: a dark foreground gives far fewer and far weaker features than a
/// sky full of stars, and they sit in a thin band across the bottom of the frame, which
/// is a poorly conditioned set of points to fit eight degrees of freedom to.  Measured
/// on 31 frames of a 33MP aurora sequence at 8 neighbours each, roughly one entry in
/// eight was wrong by tens of pixels — one of them with its sign inverted — while the
/// rest drifted smoothly.  Every entry is a source in the ground median merge, so a bad
/// one smears the ground it was meant to clean.
final class EarthHomographyContinuityTests: XCTestCase {

    // MARK: - fixtures

    private let width = 7008
    private let height = 4672

    private var probes: [(x: Double, y: Double)] {
        EarthHomographyContinuityFilter.groundProbePoints(width: width, height: height)
    }

    /// A pure translation, which is what a slow pan over a distant landscape produces to
    /// first order.  `perFrame` is the ground's drift rate in pixels per frame.
    private func drift(offset: Int, perFrame: Double = -8.1) -> [Double] {
        [
          1, 0, Double(offset) * perFrame,
          0, 1, 0,
          0, 0, 1
        ]
    }

    /// frameIndex -> offset -> matrix for a sequence whose ground drifts at a constant
    /// rate, i.e. one where nothing should be corrected.
    private func cleanSequence(
      frames: Range<Int>,
      offsets: [Int]
    ) -> [Int: [Int: [Double]]] {
        var ret: [Int: [Int: [Double]]] = [:]
        for frameIndex in frames {
            var byOffset: [Int: [Double]] = [:]
            for offset in offsets { byOffset[offset] = drift(offset: offset) }
            ret[frameIndex] = byOffset
        }
        return ret
    }

    private func allOffsets(frames: Range<Int>, offsets: [Int]) -> [Int: [Int]] {
        var ret: [Int: [Int]] = [:]
        for frameIndex in frames { ret[frameIndex] = offsets }
        return ret
    }

    // MARK: - tests

    /// A sequence that drifts smoothly is left alone.  The filter has to be able to tell
    /// "moving" from "jumping" or it would flatten the pan it is supposed to follow.
    func testSmoothSequenceIsUntouched() {
        let frames = 0..<31
        let offsets = [-4, -3, -2, -1, 1, 2, 3, 4]
        let result = EarthHomographyContinuityFilter.corrections(
          measured: cleanSequence(frames: frames, offsets: offsets),
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.filled, 0)
        XCTAssertTrue(result.corrected.isEmpty)
    }

    /// A ground that is accelerating rather than drifting at a fixed rate is still
    /// continuous, so it is still left alone.  The local model is drawn from a window of
    /// neighbouring frames, which lags a changing rate — this is the check that the lag stays inside the
    /// cutoff for a plausible acceleration.
    func testAcceleratingSequenceIsUntouched() {
        let frames = 0..<31
        let offsets = [-2, -1, 1, 2]
        var measured: [Int: [Int: [Double]]] = [:]
        for frameIndex in frames {
            // rate ramps from -4 to -12 px/frame across the sequence
            let rate = -4.0 - 8.0 * Double(frameIndex) / 30.0
            var byOffset: [Int: [Double]] = [:]
            for offset in offsets {
                byOffset[offset] = drift(offset: offset, perFrame: rate)
            }
            measured[frameIndex] = byOffset
        }
        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.replaced, 0, "a steadily accelerating pan is not a jump")
    }

    /// The case this was written for: one entry that jumped.  It is replaced, its
    /// neighbours are not, and the replacement is what the neighbours say it should be.
    func testOneJumpedEntryIsReplaced() {
        let frames = 0..<31
        let offsets = [-1, 1]
        var measured = cleanSequence(frames: frames, offsets: offsets)
        // frame 15's warp to the next frame lands 60px from where the rest of the
        // sequence puts it, and with the wrong sign — the real failure shape
        measured[15]?[1] = drift(offset: 1, perFrame: 52.0)

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.replaced, 1)
        XCTAssertEqual(result.filled, 0)
        XCTAssertEqual(Array(result.corrected.keys), [15])
        let replacement = try! XCTUnwrap(result.corrected[15]?[1])
        XCTAssertEqual(replacement[2], -8.1, accuracy: 1e-9,
                       "the replacement is the neighbours' value, not the frame's own")
        XCTAssertNil(result.corrected[15]?[-1],
                     "the offset that was fine is left as measured")
    }

    /// A frame whose alignment failed outright, for one offset, gets that offset filled
    /// in rather than dropped.  Dropping it would silently remove a source from that
    /// frame's ground merge.
    func testMissingEntryIsFilled() {
        let frames = 0..<31
        let offsets = [-1, 1]
        var measured = cleanSequence(frames: frames, offsets: offsets)
        measured[15]?[1] = nil

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.filled, 1)
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.corrected[15]?[1]?[2] ?? .nan, -8.1, accuracy: 1e-9)
    }

    /// An offset a frame is not supposed to have is never invented.  Frames near the ends
    /// of a sequence legitimately have fewer neighbours, and handing the merge a
    /// homography for a source that does not exist is worse than handing it nothing.
    func testOffsetsAFrameDoesNotHaveAreNotInvented() {
        let frames = 0..<31
        let offsets = [-2, -1, 1, 2]
        var measured = cleanSequence(frames: frames, offsets: offsets)
        // frame 0 has no frames before it
        measured[0] = [1: drift(offset: 1), 2: drift(offset: 2)]
        var expected = allOffsets(frames: frames, offsets: offsets)
        expected[0] = [1, 2]

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: expected,
          probes: probes
        )
        XCTAssertNil(result.corrected[0]?[-1])
        XCTAssertNil(result.corrected[0]?[-2])
    }

    /// Each offset is judged against the same offset in other frames, never against a
    /// different one.  The warp to the neighbour two frames back is twice the warp to the
    /// one right behind; pooling them would call every entry an outlier.
    func testOffsetsAreJudgedSeparately() {
        let frames = 0..<31
        let offsets = [-4, -1, 1, 4]
        let result = EarthHomographyContinuityFilter.corrections(
          measured: cleanSequence(frames: frames, offsets: offsets),
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(Set(result.perOffset.map(\.offset)), Set(offsets))
    }

    /// A sequence too short to build a local model from is left exactly as measured,
    /// including entries that look wrong.  Judging a frame against two neighbours is
    /// guessing.
    func testTooFewFramesToJudge() {
        let frames = 0..<3
        let offsets = [1]
        var measured = cleanSequence(frames: frames, offsets: offsets)
        measured[1]?[1] = drift(offset: 1, perFrame: 200)

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        XCTAssertEqual(result.replaced, 0)
        XCTAssertEqual(result.filled, 0)
    }

    /// The cutoff cannot be inflated past the ceiling by a noisy sequence.  A ground that
    /// is barely trackable still must not feed the merge a source tens of pixels out.
    func testCutoffIsCappedOnANoisySequence() {
        let frames = 0..<31
        let offsets = [1]
        var measured: [Int: [Int: [Double]]] = [:]
        for frameIndex in frames {
            // alternating +-15px of noise on top of the drift, so the median
            // disagreement is large and 4x it would exceed the ceiling
            let jitter = frameIndex % 2 == 0 ? 15.0 : -15.0
            measured[frameIndex] = [1: drift(offset: 1, perFrame: -8.1 + jitter)]
        }
        measured[15]?[1] = drift(offset: 1, perFrame: 90)

        let result = EarthHomographyContinuityFilter.corrections(
          measured: measured,
          expectedOffsets: allOffsets(frames: frames, offsets: offsets),
          probes: probes
        )
        let report = try! XCTUnwrap(result.perOffset.first)
        XCTAssertLessThanOrEqual(report.cutoff, EarthHomographyContinuityFilter.maxCutoff)
        XCTAssertNotNil(result.corrected[15]?[1],
                        "an entry 98px out is replaced however noisy the rest is")
    }

    // MARK: - the measure itself

    /// `maxProbeDistance` measures what a difference between two warps costs the ground,
    /// which `deviation` does not: `norm(H - I)` is dominated by where the warp sends the
    /// image origin, thousands of pixels above the ground on a landscape frame.
    func testProbeDistanceSeesWhatDeviationMisses() {
        let identity: [Double] = [1,0,0, 0,1,0, 0,0,1]
        // A vertical scale of 1.005 about y = 4400, which is down in the ground.  It
        // leaves that row exactly where it was and moves the rest of the ground by a
        // few pixels — but to hold that fixed point it needs a translation term of
        // (1 - 1.005) * 4400 = -22px, and that term is the whole of `deviation`.
        let scale = 1.005
        let fixedRow = 4400.0
        let verticalScale: [Double] = [
          1, 0,     0,
          0, scale, (1 - scale) * fixedRow,
          0, 0,     1
        ]
        let deviation = homographyDeviation(verticalScale)
        let probeDistance = maxProbeDistance(between: verticalScale, and: identity,
                                             at: probes)
        XCTAssertEqual(deviation, 22, accuracy: 0.1,
                       "norm(H - I) is the translation column, i.e. the displacement " +
                       "at the image origin")
        XCTAssertLessThan(probeDistance, 5,
                          "nothing in the ground moves anywhere near 22px")
        XCTAssertGreaterThan(probeDistance, 1)
    }

    /// The local model is one of the measured warps, picked for agreeing with the rest,
    /// and a wild member does not get to be it.
    func testMedoidIgnoresAWildMember() {
        let good = drift(offset: 1)
        let wild = drift(offset: 1, perFrame: 900)
        let model = medoidHomography(of: [good, good, wild, good, good], at: probes)
        XCTAssertEqual(model[2], -8.1, accuracy: 1e-9)
    }

    /// The model is always a member of the window, never a blend of them.  An
    /// element-wise average or median can pair one frame's projective row with
    /// another's translation, which is a matrix no frame measured.
    func testMedoidReturnsAMemberOfTheWindow() {
        let a = drift(offset: 1, perFrame: -8.0)
        let b = drift(offset: 1, perFrame: -8.2)
        let c = drift(offset: 1, perFrame: -8.4)
        let model = medoidHomography(of: [a, b, c], at: probes)
        XCTAssertTrue([a, b, c].contains { $0 == model })
        XCTAssertEqual(model[2], -8.2, accuracy: 1e-9, "and it is the middle one")
    }

    /// Probe points sit in the bottom of the frame, where the ground is, and spread
    /// across its width without reaching the edges — see `groundProbePoints` for why
    /// both of those matter.
    func testGroundProbePointsSampleTheGroundAcrossTheWidth() {
        let points = EarthHomographyContinuityFilter.groundProbePoints(width: width,
                                                                      height: height)
        XCTAssertFalse(points.isEmpty)
        for point in points {
            XCTAssertGreaterThanOrEqual(point.y, Double(height) * 0.9,
                                        "probing higher reaches above a typical horizon")
            XCTAssertLessThanOrEqual(point.y, Double(height - 1))
        }
        let xs = points.map(\.x)
        XCTAssertGreaterThan(xs.min() ?? 0, 0)
        XCTAssertLessThan(xs.max() ?? Double(width), Double(width - 1))
        XCTAssertGreaterThan((xs.max() ?? 0) - (xs.min() ?? 0), Double(width) * 0.6,
                             "and they still span most of the width")
    }
}
