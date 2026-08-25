import XCTest
@testable import StarCore
import StarCppBridge

/// The pieces behind the static-cadence check: measuring a capture gap's real
/// duration from star positions or from the images, and synthesizing the median
/// warp for a span that is not a whole number of nominal steps.
final class CaptureCadenceTests: XCTestCase {

    // one nominal step: mostly translation with a whisper of rotation, the shape a
    // real sidereal step has
    private let oneStep: [Double] = [
      1.0003, 0.0009, -10.0,
      0.0013, 1.0003, -12.0,
      0.0,    0.0,    1.0,
    ]

    private func driftPerStep(at p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let inverse = CaptureCadence.invert3x3(oneStep)!
        let q = CaptureCadence.apply(inverse, to: p)!
        return (x: q.x - p.x, y: q.y - p.y)
    }

    private func starField(count: Int, seed: UInt64) -> [(x: Double, y: Double)] {
        var state = seed
        func random() -> Double {
            // xorshift, deterministic across runs
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000.0
        }
        return (0..<count).map { _ in
            (x: 100 + random() * 7000, y: 100 + random() * 4000)
        }
    }

    private func moved(_ points: [(x: Double, y: Double)],
                       bySpan span: Double,
                       jitter: Double = 0.2,
                       seed: UInt64 = 99) -> [(x: Double, y: Double)] {
        var state = seed
        func random() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000.0 - 0.5
        }
        return points.map { p in
            let d = driftPerStep(at: p)
            return (x: p.x + d.x * span + random() * jitter,
                    y: p.y + d.y * span + random() * jitter)
        }
    }

    // MARK: - matchedStarSpan

    func testANominalGapMeasuresOneStep() throws {
        let earlier = starField(count: 500, seed: 7)
        let later = moved(earlier, bySpan: 1.0)
        let m = try XCTUnwrap(
          CaptureCadence.matchedStarSpan(from: earlier, to: later, oneStep: oneStep)
        )
        XCTAssertEqual(m.span, 1.0, accuracy: 0.05)
        XCTAssertNotNil(CaptureCadence.trustedSpan(m))
    }

    func testALongGapMeasuresItsRealDuration() throws {
        let earlier = starField(count: 500, seed: 11)
        let later = moved(earlier, bySpan: 1.54)
        let m = try XCTUnwrap(
          CaptureCadence.matchedStarSpan(from: earlier, to: later, oneStep: oneStep)
        )
        XCTAssertEqual(m.span, 1.54, accuracy: 0.05)
        XCTAssertEqual(CaptureCadence.trustedSpan(m) ?? -1, 1.54, accuracy: 0.05)
    }

    func testFixedPatternPointsDoNotVote() throws {
        // hot pixels and dust sit at the same coordinates in both frames; at dusk
        // they can outnumber the stars, and they must not drag the answer to zero
        let stars = starField(count: 400, seed: 13)
        let artifacts = starField(count: 300, seed: 17)
        let earlier = stars + artifacts
        let later = moved(stars, bySpan: 1.0) + artifacts
        let m = try XCTUnwrap(
          CaptureCadence.matchedStarSpan(from: earlier, to: later, oneStep: oneStep)
        )
        XCTAssertEqual(m.span, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(m.stationaryFraction, 0.1,
                             "the artifacts have to be seen and counted, not matched")
    }

    func testCloudsMovingTheirOwnWayAreIgnored() throws {
        let stars = starField(count: 400, seed: 19)
        // clouds drift uniformly in a direction of their own, tens of pixels
        let clouds = starField(count: 400, seed: 23)
        let earlier = stars + clouds
        let later = moved(stars, bySpan: 1.0)
          + clouds.map { (x: $0.x + 31.0, y: $0.y - 18.0) }
        let m = try XCTUnwrap(
          CaptureCadence.matchedStarSpan(from: earlier, to: later, oneStep: oneStep)
        )
        XCTAssertEqual(m.span, 1.0, accuracy: 0.05)
    }

    func testAVeryShortGapIsNotTrusted() throws {
        // under a third of a step the motion is a pixel or two — position matching
        // cannot tell that from the fixed-pattern points it excludes, so the answer
        // must be "measure this one from the images" rather than a number
        let earlier = starField(count: 500, seed: 29)
        let later = moved(earlier, bySpan: 0.19)
        let m = CaptureCadence.matchedStarSpan(from: earlier, to: later, oneStep: oneStep)
        XCTAssertNil(CaptureCadence.trustedSpan(m))
    }

    // MARK: - fractionalHomography

    func testAWholeSpanIsTheAnchorItself() throws {
        let anchors = [1: oneStep]
        let h = try XCTUnwrap(
          CaptureCadence.fractionalHomography(atSpan: 1.0, anchors: anchors)
        )
        XCTAssertEqual(h, oneStep)
    }

    func testAZeroSpanIsIdentity() throws {
        let h = try XCTUnwrap(
          CaptureCadence.fractionalHomography(atSpan: 0.0, anchors: [1: oneStep])
        )
        for (value, expected) in zip(h, [1.0, 0, 0, 0, 1, 0, 0, 0, 1]) {
            XCTAssertEqual(value, expected, accuracy: 1e-12)
        }
    }

    func testAFractionalSpanMovesAFractionAsFar() throws {
        let h = try XCTUnwrap(
          CaptureCadence.fractionalHomography(atSpan: 0.19, anchors: [1: oneStep])
        )
        let p = (x: 3000.0, y: 2000.0)
        let full = CaptureCadence.apply(oneStep, to: p)!
        let part = CaptureCadence.apply(h, to: p)!
        XCTAssertEqual(part.x - p.x, (full.x - p.x) * 0.19, accuracy: 0.05)
        XCTAssertEqual(part.y - p.y, (full.y - p.y) * 0.19, accuracy: 0.05)
    }

    func testASpanBetweenAnchorsInterpolatesThem() throws {
        // anchors at 3 and 4 with a deliberate bend between them: the bracketing
        // pair decides, not a global slope through every anchor
        var three = oneStep
        three[2] = -31.0
        three[5] = -37.0
        var four = oneStep
        four[2] = -39.0
        four[5] = -47.0
        let h = try XCTUnwrap(
          CaptureCadence.fractionalHomography(atSpan: 3.25,
                                              anchors: [1: oneStep, 3: three, 4: four])
        )
        XCTAssertEqual(h[2], -33.0, accuracy: 1e-9)
        XCTAssertEqual(h[5], -39.5, accuracy: 1e-9)
    }

    func testANegativeSpanUsesTheNegativeSide() throws {
        var minusOne = oneStep
        minusOne[2] = 10.0
        minusOne[5] = 12.0
        let h = try XCTUnwrap(
          CaptureCadence.fractionalHomography(atSpan: -0.5,
                                              anchors: [-1: minusOne, 1: oneStep])
        )
        XCTAssertEqual(h[2], 5.0, accuracy: 1e-9)
        XCTAssertEqual(h[5], 6.0, accuracy: 1e-9)
    }

    func testNoAnchorsMeansNoAnswer() {
        XCTAssertNil(CaptureCadence.fractionalHomography(atSpan: 0.5, anchors: [:]))
    }

    // MARK: - cadenceAwareNeighborHomography

    private func medianSet(for frameIndex: Int) -> HomographyResultsCodable {
        var entries: [AlignmentWarpInfoCodable] = []
        for offset in [-4, -3, -2, -1, 1, 2, 3, 4] {
            var h: [Double] = [1, 0, -10.0 * Double(offset),
                               0, 1, -12.0 * Double(offset),
                               0, 0, 1]
            h[0] = 1.0
            entries.append(
              AlignmentWarpInfoCodable(
                homography: h,
                alignmentState: .homographySuccess,
                frameIndex: frameIndex + offset
              )
            )
        }
        return HomographyResultsCodable(for: frameIndex, with: entries)
    }

    func testNoAnomaliesReproducesTheStampedEntriesExactly() {
        let median = medianSet(for: 100)
        let target = 40
        let neighbors = [36, 37, 38, 39, 41, 42, 43, 44]
        let stamped = extrapolateNeighborHomography(
          from: median, toFrameIndex: target, targetNeighborFrameIndices: neighbors)
        let aware = cadenceAwareNeighborHomography(
          from: median, toFrameIndex: target, targetNeighborFrameIndices: neighbors,
          anomalousGaps: [:])
        XCTAssertEqual(stamped.count, aware.count)
        for (a, b) in zip(stamped, aware) {
            XCTAssertEqual(a.frameIndex, b.frameIndex)
            XCTAssertEqual(a.homography, b.homography)
            XCTAssertEqual(a.alignmentState, b.alignmentState)
        }
    }

    func testAFarAwayAnomalyChangesNothing() {
        let median = medianSet(for: 100)
        let target = 40
        let neighbors = [36, 37, 38, 39, 41, 42, 43, 44]
        let stamped = extrapolateNeighborHomography(
          from: median, toFrameIndex: target, targetNeighborFrameIndices: neighbors)
        let aware = cadenceAwareNeighborHomography(
          from: median, toFrameIndex: target, targetNeighborFrameIndices: neighbors,
          anomalousGaps: [500: 0.2])
        for (a, b) in zip(stamped, aware) {
            XCTAssertEqual(a.homography, b.homography)
            XCTAssertEqual(a.alignmentState, b.alignmentState)
        }
    }

    func testPairsSpanningAnAnomalousGapGetScaledWarps() throws {
        let median = medianSet(for: 100)
        // the gap between frames 9 and 10 was a fifth of the usual interval
        let anomalies = [9: 0.2]
        let target = 10
        let neighbors = [6, 7, 8, 9, 11, 12, 13, 14]
        let rebuilt = cadenceAwareNeighborHomography(
          from: median, toFrameIndex: target, targetNeighborFrameIndices: neighbors,
          anomalousGaps: anomalies)
        let byIndex = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.frameIndex, $0) })

        // neighbour 9 is one gap back, and that gap lasted 0.2 steps: the warp is a
        // fifth of a step, not a whole one
        let nine = try XCTUnwrap(byIndex[9]?.homography)
        XCTAssertEqual(nine[2], 0.2 * 10.0, accuracy: 1e-9)
        XCTAssertEqual(nine[5], 0.2 * 12.0, accuracy: 1e-9)
        XCTAssertEqual(byIndex[9]?.alignmentState, .usedExistingHomography)

        // neighbour 8 spans that gap plus a nominal one: 1.2 steps
        let eight = try XCTUnwrap(byIndex[8]?.homography)
        XCTAssertEqual(eight[2], 1.2 * 10.0, accuracy: 1e-9)
        XCTAssertEqual(eight[5], 1.2 * 12.0, accuracy: 1e-9)

        // neighbours on the other side span only nominal gaps and keep the
        // stamped matrices untouched
        let eleven = try XCTUnwrap(byIndex[11]?.homography)
        XCTAssertEqual(eleven[2], -10.0, accuracy: 1e-12)
        XCTAssertEqual(eleven[5], -12.0, accuracy: 1e-12)
        XCTAssertEqual(byIndex[11]?.alignmentState, .homographySuccess)
    }

    // MARK: - measuredSpan (phase correlation through the bridge)

    private func dotImage(width: Int, height: Int,
                          dots: [(x: Int, y: Int)],
                          shiftX: Int = 0, shiftY: Int = 0) -> PixelatedImage {
        var bytes = [UInt8](repeating: 8, count: width * height)
        for dot in dots {
            let x = dot.x + shiftX
            let y = dot.y + shiftY
            guard x > 0, y > 0, x < width - 1, y < height - 1 else { continue }
            for dy in -1...1 {
                for dx in -1...1 {
                    bytes[(y + dy) * width + (x + dx)] = 240
                }
            }
        }
        return bytes.withUnsafeMutableBytes { ptr in
            let mat = MatWrapper(
              width: width, height: height,
              cvType: 0, // CV_8UC1
              bytesPerRow: width,
              data: ptr.baseAddress!,
              takeOwnership: false
            )
            return PixelatedImage(mat: mat.clone())!
        }
    }

    func testConsensusAcceptsCropsThatAgree() throws {
        var state: UInt64 = 777
        func random(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        // dots everywhere, all moving the same way: every crop measures the same span
        let dots = (0..<4000).map { _ in (x: 20 + random(1496), y: 20 + random(472)) }
        let earlier = dotImage(width: 1536, height: 512, dots: dots)
        let later = dotImage(width: 1536, height: 512, dots: dots, shiftX: 3, shiftY: 5)
        let step: [Double] = [1, 0, -3, 0, 1, -5, 0, 0, 1]
        let crops = [(x: 0, y: 0, size: 512), (x: 512, y: 0, size: 512), (x: 1024, y: 0, size: 512)]
        let span = try XCTUnwrap(
          CaptureCadence.consensusSpan(from: earlier, to: later, oneStep: step, crops: crops)
        )
        XCTAssertEqual(span, 1.0, accuracy: 0.05)
    }

    func testConsensusRejectsCropsThatDisagree() throws {
        var state: UInt64 = 888
        func random(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        // the left half moves like the sky; the right half stays put, the way
        // fixed-pattern content does — the two crops must not average into a
        // half-true answer, they must produce none
        let moving = (0..<2000).map { _ in (x: 20 + random(472), y: 20 + random(472)) }
        let stuck = (0..<2000).map { _ in (x: 532 + random(472), y: 20 + random(472)) }
        let earlier = dotImage(width: 1024, height: 512, dots: moving + stuck)
        var laterDots = moving.map { (x: $0.x + 3, y: $0.y + 5) }
        laterDots += stuck
        let later = dotImage(width: 1024, height: 512, dots: laterDots)
        let step: [Double] = [1, 0, -3, 0, 1, -5, 0, 0, 1]
        let crops = [(x: 0, y: 0, size: 512), (x: 512, y: 0, size: 512)]
        XCTAssertNil(
          CaptureCadence.consensusSpan(from: earlier, to: later, oneStep: step, crops: crops)
        )
    }

    func testMeasuredSpanReadsTheShiftFromTheImages() throws {
        var state: UInt64 = 4242
        func random(_ bound: Int) -> Int {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Int(state % UInt64(bound))
        }
        let dots = (0..<1500).map { _ in (x: 20 + random(472), y: 20 + random(472)) }
        let earlier = dotImage(width: 512, height: 512, dots: dots)
        let later = dotImage(width: 512, height: 512, dots: dots, shiftX: 3, shiftY: 5)

        // a model step of exactly the true shift: the span must read 1.0
        let step: [Double] = [1, 0, -3, 0, 1, -5, 0, 0, 1]
        let one = try XCTUnwrap(
          CaptureCadence.measuredSpan(from: earlier, to: later, oneStep: step,
                                      cropX: 0, cropY: 0, cropSize: 512)
        )
        XCTAssertEqual(one.span, 1.0, accuracy: 0.05)
        XCTAssertGreaterThan(one.response, 0.5,
                             "clean synthetic dots correlate decisively")

        // a model step twice as long: the same images now cover half a step
        let doubleStep: [Double] = [1, 0, -6, 0, 1, -10, 0, 0, 1]
        let half = try XCTUnwrap(
          CaptureCadence.measuredSpan(from: earlier, to: later, oneStep: doubleStep,
                                      cropX: 0, cropY: 0, cropSize: 512)
        )
        XCTAssertEqual(half.span, 0.5, accuracy: 0.05)
    }
}
