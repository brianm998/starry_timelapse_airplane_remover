import XCTest
import StarCppBridge
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
        // Measured on the OpenCV detector paths; the GPU ports have their own table,
        // pinned in KeypointPathMemoryTests.
        c.useGPUForSIFT = false
        c.useGPUForAKAZE = false
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
        full.resourceProfile = .custom
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

/// The per-detector, per-path keypoint reservations, against what was measured: one real
/// `ia_find_features` per fresh process (StarCpp's `KeypointFootprintMeasurement`), 33MP
/// and 42MP agreeing to within 0.3x. Whole-op peak as a multiple of the working frame.
final class KeypointPathMemoryTests: XCTestCase {

    private func config(gpu: Bool, divisor: Double) -> Config {
        var c = Config()
        c.useGPUForSIFT = gpu
        c.useGPUForAKAZE = gpu
        c.alignmentKeypointDetectionDivisor = divisor
        c.keypointDivisorWasChosen = true
        return c
    }

    private let measured: [(gpu: Bool, earth: Bool, divisor: Double, multiple: Double)] = [
      (false, false, 1.0, 42.3), (false, false, 1.5, 21.9), (false, false, 2.0, 12.9),
      (true,  false, 1.0, 53.9), (true,  false, 1.5, 29.5), (true,  false, 2.0, 17.3),
      (false, true,  1.0, 28.7), (false, true,  1.5, 16.3), (false, true,  2.0, 10.9),
      (true,  true,  1.0, 38.8), (true,  true,  1.5, 20.9), (true,  true,  2.0, 13.8),
    ]

    func testEveryPathReservesAtLeastWhatItWasMeasuredToPeakAt() throws {
        try XCTSkipUnless(GPUCapability.isAvailable() || !measured.contains { $0.gpu } ,
                          "GPU rows need a GPU")
        for row in measured {
            if row.gpu && !GPUCapability.isAvailable() { continue }
            let c = config(gpu: row.gpu, divisor: row.divisor)
            let reserved = Double(c.effectiveKeypointMemoryMultiplier(for: row.earth ? .earth : .sky))
            // 5% slack: the OpenCV sky figures (42/21/14) predate these measurements and
            // were validated at ~95% of real frames; this synthetic frame's 42.3 includes its
            // mask. The GPU and earth rows carry ~5% headroom outright.
            XCTAssertGreaterThanOrEqual(
              reserved, row.multiple * 0.95,
              "\(row.earth ? "earth" : "sky") \(row.gpu ? "GPU" : "OpenCV") at divisor "
              + "\(row.divisor) peaks at \(row.multiple)x and was only charged \(reserved)x")
        }
    }

    func testTheGPUSkyPathCostsMoreThanOpenCVs() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "needs a GPU")
        XCTAssertGreaterThan(config(gpu: true, divisor: 1).effectiveKeypointMemoryMultiplier(for: .sky),
                             config(gpu: false, divisor: 1).effectiveKeypointMemoryMultiplier(for: .sky),
                             "the GPU SIFT port was measured at 53.9x against OpenCV's 42.3x")
    }

    func testTheDefaultOpenCVSkyFigureIsUnchanged() {
        XCTAssertEqual(config(gpu: false, divisor: 1).effectiveKeypointMemoryMultiplier(), 42)
        XCTAssertEqual(config(gpu: false, divisor: 1.5).effectiveKeypointMemoryMultiplier(), 21)
        XCTAssertEqual(config(gpu: false, divisor: 2).effectiveKeypointMemoryMultiplier(), 14)
    }

    func testTheLimiterSizesItselfFromTheCheapestPath() {
        var c = config(gpu: false, divisor: 1)
        c.imageWidth = 7008; c.imageHeight = 4672
        c.imageBytesPerPixel = 6; c.imageBitsPerComponent = 16
        let kc = c.keypointConcurrency(physicalMemory: 36 * 1024 * 1024 * 1024)
        XCTAssertEqual(kc.bytesPerOp,
                       c.workingFrameBytes * UInt64(c.effectiveKeypointMemoryMultiplier(for: .earth)),
                       "the ledger charges each op its own path; this gate must not refuse what it admits")
    }
}
