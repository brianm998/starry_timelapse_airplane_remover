import XCTest
@testable import StarCore

/// Tests for `alignmentKeypointDetectionDivisor`, which replaced the
/// `alignmentHalfResolutionKeypoints` bool.
///
/// Three things here are load-bearing and had no coverage before:
///
///   - Old config.json files hold the bool. `decodeIfPresent(Double.self)` against a JSON
///     `true` throws typeMismatch rather than returning nil, so getting the fallback wrong
///     does not mean "the setting reverts to default" — it means the whole decode throws
///     and every resume of an existing sequence dies.
///   - The cache filename encodes the divisor. A descriptor describes the patch at the
///     resolution it was computed at, so if two divisors can produce one filename, a run
///     silently matches 1.5 descriptors against 2.0 descriptors and the homography is
///     quietly wrong. `keypointFilename` had no tests at all.
///   - The C++ takes a scale and treats anything >= 1.0 as full resolution WITHOUT
///     complaining. So a divisor that reaches it unconverted or unclamped detects at full
///     size while the filename claims otherwise. Only `Config` can prevent that.
final class KeypointDivisorTests: XCTestCase {

    private func config(megapixels: Double = 42.2) -> Config {
        var c = Config()
        let height = (megapixels * 1_000_000 / 1.5).squareRoot()
        c.imageHeight = Int(height.rounded())
        c.imageWidth = Int((height * 1.5).rounded())
        c.imageBytesPerPixel = 6
        c.imageBitsPerComponent = 16
        return c
    }

    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    // MARK: - Old configs must keep loading

    func testLegacyTrueBecomesTwo() throws {
        let c = try decode(#"{"alignmentHalfResolutionKeypoints": true}"#)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 2.0,
                       "the bool's true meant a half-size copy, which is a divisor of 2")
    }

    func testLegacyFalseBecomesOne() throws {
        let c = try decode(#"{"alignmentHalfResolutionKeypoints": false}"#)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
    }

    /// The regression that would have hurt most: not a wrong value, a thrown decode.
    func testLegacyBoolDoesNotBreakTheWholeDecode() throws {
        let json = #"{"alignmentHalfResolutionKeypoints": true, "imageWidth": 7952}"#
        let c = try decode(json)
        XCTAssertEqual(c.imageWidth, 7952,
                       "a legacy bool must not throw and take every other setting with it")
    }

    func testNewKeyWinsWhenBothArePresent() throws {
        let c = try decode(#"{"alignmentKeypointDetectionDivisor": 1.5, "alignmentHalfResolutionKeypoints": true}"#)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.5)
    }

    func testAbsentKeysLeaveTheDefault() throws {
        let c = try decode(#"{"imageWidth": 100}"#)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
    }

    func testDivisorSurvivesARoundTrip() throws {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 1.5
        let back = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(back.alignmentKeypointDetectionDivisor, 1.5)
    }

    // MARK: - Divisor to scale, and the clamp the C++ cannot do for us

    func testScaleIsTheReciprocal() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 2.0
        XCTAssertEqual(c.keypointDetectionScale, 0.5, accuracy: 1e-12)
        c.alignmentKeypointDetectionDivisor = 1.5
        XCTAssertEqual(c.keypointDetectionScale, 2.0 / 3.0, accuracy: 1e-12)
    }

    func testNonsenseDivisorsClampToFullResolution() {
        for bad in [1.0, 0.5, 0.0, -3.0] {
            var c = config()
            c.alignmentKeypointDetectionDivisor = bad
            XCTAssertEqual(c.keypointDetectionScale, 1.0,
                           "divisor \(bad) must read as full resolution, and must never "
                           + "reach the C++ as a scale >= 1.0 by accident")
        }
    }

    // MARK: - Cache keying

    func testFilenameIsUnchangedAtTheTwoLegacyValues() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 1.0
        XCTAssertEqual(c.keypointFilename(frameIndex: 3, ofType: .starAligned), "3.sky.yaml")
        c.alignmentKeypointDetectionDivisor = 2.0
        XCTAssertEqual(c.keypointFilename(frameIndex: 3, ofType: .starAligned), "3.sky.half.yaml",
                       "feature files written in the bool era must stay reachable")
    }

    func testFilenameEncodesOtherDivisors() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 1.5
        XCTAssertEqual(c.keypointFilename(frameIndex: 3, ofType: .starAligned), "3.sky.div1.50.yaml")
        XCTAssertEqual(c.keypointFilename(frameIndex: 3, ofType: .earthAligned), "3.earth.div1.50.yaml")
    }

    /// The invariant that matters: no two divisors may share a filename, or one run's
    /// descriptors get matched against another's.
    func testEveryDivisorGetsItsOwnFilename() {
        var seen: [String: Double] = [:]
        for divisor in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0] {
            var c = config()
            c.alignmentKeypointDetectionDivisor = divisor
            let name = c.keypointFilename(frameIndex: 7, ofType: .starAligned)!
            if let clash = seen[name] {
                XCTFail("divisor \(divisor) and \(clash) both produce \(name)")
            }
            seen[name] = divisor
            XCTAssertTrue(name.hasSuffix(".yaml"),
                          "OpenCV FileStorage picks its format from the extension")
        }
    }

    /// Float drift must not produce a filename no later run can find.
    func testFilenameIsStableAgainstFloatDrift() {
        var exact = config();   exact.alignmentKeypointDetectionDivisor = 1.5
        var drifted = config(); drifted.alignmentKeypointDetectionDivisor = 1.4999999999999998
        XCTAssertEqual(exact.keypointFilename(frameIndex: 1, ofType: .starAligned),
                       drifted.keypointFilename(frameIndex: 1, ofType: .starAligned))
    }

    /// The name has to be built from the same quantized value the work is sized by, or the
    /// file could describe a scale that was never used.
    func testQuantizationIsSharedWithTheFilename() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 1.4999999999999998
        XCTAssertEqual(c.quantizedKeypointDivisor, 1.5)
    }

    // MARK: - Memory, which nothing scaled before

    func testMultiplierFallsWithTheSquareOfTheDivisor() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 1.0
        XCTAssertEqual(c.effectiveKeypointMemoryMultiplier(), 42)
        c.alignmentKeypointDetectionDivisor = 1.5
        XCTAssertEqual(c.effectiveKeypointMemoryMultiplier(), 21)
        c.alignmentKeypointDetectionDivisor = 2.0
        XCTAssertEqual(c.effectiveKeypointMemoryMultiplier(), 14)
    }

    func testMultiplierNeverFallsBelowTheNonScalingPart() {
        var c = config()
        c.alignmentKeypointDetectionDivisor = 64
        XCTAssertGreaterThanOrEqual(c.effectiveKeypointMemoryMultiplier(), 4,
                                    "the original frame, its gray copy and the mask do "
                                    + "not shrink — the downscale happens after them")
    }

    /// The whole point of scaling the reservation: a reduced-resolution run should be
    /// allowed more keypoint ops at once, not the same number as a full-res run.
    func testReducedResolutionBuysConcurrency() {
        let physical: UInt64 = 128 * 1024 * 1024 * 1024
        var full = config()
        full.numberOfFramesToProcessConcurrently = 64   // so memory is the binding term
        var reduced = full
        reduced.alignmentKeypointDetectionDivisor = 2.0

        let a = full.keypointConcurrency(physicalMemory: physical)
        let b = reduced.keypointConcurrency(physicalMemory: physical)
        XCTAssertEqual(a.binding, "memory budget")
        XCTAssertGreaterThan(b.limit, a.limit,
                             "detecting on a quarter of the pixels reserved 42x anyway "
                             + "before this, so a half-res run got a full-res run's "
                             + "concurrency for no reason")
    }
}
