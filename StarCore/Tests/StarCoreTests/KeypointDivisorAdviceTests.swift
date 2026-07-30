import XCTest
@testable import StarCore

/// Tests for `keypointDivisorAdvice(physicalMemory:)`, which decides whether the GUI's
/// startup flow offers the keypoint divisor expanded and pre-set, or collapsed and at full
/// resolution.
///
/// The reason this needs tests rather than eyeballing: it is the only place in the codebase
/// that runs the memory arithmetic *backwards* — every other user of
/// `keypointMemoryMultiplier` multiplies a known resolution to get bytes, while this one
/// divides a byte budget to get a resolution back. An error in that direction does not
/// crash or over-reserve, it just puts the advice at the wrong resolution, which is
/// invisible until someone with a different machine reports that Star told them the wrong
/// thing.
///
/// The anchor case is a real machine and a real observation: on a 128GB 18-core (36
/// logical) iMac Pro, 12MP sequences run at full resolution comfortably and 42MP ones
/// choke. Anything that moves the crossover off that boundary is a regression regardless of
/// how defensible the new arithmetic looks.
final class KeypointDivisorAdviceTests: XCTestCase {

    private static let iMacProMemory: UInt64 = 128 * 1024 * 1024 * 1024
    private static let iMacProCores = 36

    /// A 3:2 16-bit 3-channel frame of the given size, which is what the pipeline sees
    /// from the cameras this is aimed at.
    private func config(megapixels: Double,
                        cores: Int = KeypointDivisorAdviceTests.iMacProCores) -> Config {
        var c = Config()
        let height = (megapixels * 1_000_000 / 1.5).squareRoot()
        c.imageHeight = Int(height.rounded())
        c.imageWidth = Int((height * 1.5).rounded())
        c.imageBytesPerPixel = 6
        c.imageBitsPerComponent = 16
        c.numberOfFramesToProcessConcurrently = cores
        return c
    }

    private func advice(_ c: Config,
                        memory: UInt64 = KeypointDivisorAdviceTests.iMacProMemory)
      -> Config.KeypointDivisorAdvice
    {
        guard let a = c.keypointDivisorAdvice(physicalMemory: memory) else {
            XCTFail("advice should exist once imageInfo is set")
            return Config.KeypointDivisorAdvice(reduceRecommended: false,
                                                recommendedDivisor: 1,
                                                thresholdPixels: 0,
                                                imagePixels: 0,
                                                fullResolutionConcurrency: 0,
                                                frameConcurrency: 0)
        }
        return a
    }

    // MARK: - The machine the observation came from

    /// 12MP is the size the user reports running full resolution without trouble.
    func testTwelveMegapixelsNeedsNothingOnA128GBMachine() {
        let a = advice(config(megapixels: 12))
        XCTAssertFalse(a.reduceRecommended,
                       "12MP full-res was measured as comfortable on this machine; "
                       + "prompting here would be advice nobody needs")
        XCTAssertEqual(a.recommendedDivisor, 1.0)
        XCTAssertEqual(a.fullResolutionConcurrency, a.frameConcurrency,
                       "below the crossover the core count is what binds, so a divisor "
                       + "buys no concurrency at all")
    }

    /// 42MP is the size that choked, and the whole reason the divisor got a UI.
    func testFortyTwoMegapixelsIsRecommendedDownOnA128GBMachine() {
        let a = advice(config(megapixels: 42.2))
        XCTAssertTrue(a.reduceRecommended)
        XCTAssertEqual(a.recommendedDivisor, Config.recommendedReducedKeypointDivisor)
        XCTAssertLessThan(a.fullResolutionConcurrency, a.frameConcurrency,
                          "the observable is a machine that cannot fill its cores")
    }

    /// Pins the crossover to the measured boundary rather than to whatever the arithmetic
    /// happens to produce. 12.9MP is what the defaults give; the window is wide enough
    /// that tuning a multiplier by a unit does not fail this, and narrow enough that
    /// landing on the wrong side of either observation does.
    func testTheCrossoverSitsBetweenTheTwoObservations() {
        let a = advice(config(megapixels: 42.2))
        let mp = Double(a.thresholdPixels) / 1_000_000
        XCTAssertGreaterThan(mp, 12.0, "12MP was observed to be fine")
        XCTAssertLessThan(mp, 42.2, "42MP was observed to choke")
        XCTAssertEqual(mp, 12.9, accuracy: 0.2,
                       "the defaults put it here; if this moved, something upstream "
                       + "changed the memory arithmetic and the advice moved with it")
    }

    // MARK: - Coherence between the threshold and the decision

    /// `thresholdPixels` is documented as the largest frame that still fits, and
    /// `reduceRecommended` as exactly `imagePixels > thresholdPixels`. Two independently
    /// floored divisions could disagree by a pixel at the boundary; they must not, or the
    /// UI shows a threshold that contradicts its own recommendation.
    func testTheThresholdIsExactlyWhereTheDecisionFlips() {
        let threshold = advice(config(megapixels: 42.2)).thresholdPixels

        var atIt = config(megapixels: 42.2)
        atIt.imageWidth = threshold
        atIt.imageHeight = 1
        XCTAssertFalse(advice(atIt).reduceRecommended,
                       "a frame exactly at the threshold still fits")

        var justOver = atIt
        justOver.imageWidth = threshold + 1
        XCTAssertTrue(advice(justOver).reduceRecommended,
                      "one pixel more does not")
    }

    func testDecisionAlwaysAgreesWithTheReportedConcurrency() {
        for mp in [4.0, 8.0, 12.0, 16.0, 24.0, 42.2, 61.0, 100.0] {
            let a = advice(config(megapixels: mp))
            XCTAssertEqual(a.reduceRecommended,
                           a.fullResolutionConcurrency < a.frameConcurrency,
                           "at \(mp)MP the recommendation and the concurrency it is "
                           + "justified by disagree")
            XCTAssertEqual(a.reduceRecommended, a.imagePixels > a.thresholdPixels,
                           "at \(mp)MP the recommendation and the threshold shown "
                           + "alongside it disagree")
        }
    }

    // MARK: - It has to scale with the machine, not be a constant in disguise

    func testMoreMemoryRaisesTheThresholdProportionally() {
        let c = config(megapixels: 42.2)
        let small = advice(c, memory: 32 * 1024 * 1024 * 1024).thresholdPixels
        let large = advice(c, memory: 128 * 1024 * 1024 * 1024).thresholdPixels
        XCTAssertEqual(Double(large) / Double(small), 4.0, accuracy: 0.01,
                       "four times the memory should be four times the frame")
    }

    func testMoreCoresLowersTheThreshold() {
        let few = advice(config(megapixels: 42.2, cores: 8)).thresholdPixels
        let many = advice(config(megapixels: 42.2, cores: 36)).thresholdPixels
        XCTAssertLessThan(many, few,
                          "a machine that wants more ops in flight runs out of memory at "
                          + "a smaller frame, not a larger one — this is the term most "
                          + "likely to get dropped as counterintuitive")
    }

    /// Spot-checks the two ends of the machines this ships to, so a change that only looks
    /// right on the developer's iMac Pro is caught.
    func testTheAdviceIsSaneOnSmallAndHugeMachines() {
        // 16GB 8-core laptop.
        let laptop = advice(config(megapixels: 42.2, cores: 8),
                            memory: 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(Double(laptop.thresholdPixels) / 1_000_000, 7.2, accuracy: 0.5)
        XCTAssertTrue(laptop.reduceRecommended, "24MP and up is most cameras")

        // 192GB 24-core Ultra.
        let ultra = advice(config(megapixels: 42.2, cores: 24),
                           memory: 192 * 1024 * 1024 * 1024)
        XCTAssertEqual(Double(ultra.thresholdPixels) / 1_000_000, 29.0, accuracy: 1.0)
        XCTAssertTrue(ultra.reduceRecommended,
                      "42MP is past even this machine at full resolution")
        XCTAssertFalse(advice(config(megapixels: 24, cores: 24),
                             memory: 192 * 1024 * 1024 * 1024).reduceRecommended,
                       "but 24MP is not, and it should not be told otherwise")
    }

    // MARK: - What it must not depend on

    /// The question is what full resolution would cost. If the advice used
    /// `effectiveKeypointMemoryMultiplier()` it would answer a different question once a
    /// divisor was set — and since the GUI sets one on appear, the explanation shown to the
    /// user would contradict the reason it was shown.
    func testTheAdviceDoesNotMoveOnceADivisorIsSet() {
        var c = config(megapixels: 42.2)
        let before = advice(c)
        c.alignmentKeypointDetectionDivisor = 2.0
        let after = advice(c)
        XCTAssertEqual(before, after,
                       "advice about full resolution must not change when the setting it "
                       + "recommends is applied")
    }

    /// `workingBytesPerPixel` floors at the 16-bit working depth, so 8-bit input must not
    /// be told it can handle twice the resolution — the pipeline promotes it and the
    /// keypoint cost is per pixel either way.
    func testAnEightBitSourceGetsTheSameThresholdAsSixteen() {
        var eight = config(megapixels: 42.2)
        eight.imageBytesPerPixel = 3
        eight.imageBitsPerComponent = 8
        XCTAssertEqual(eight.workingBytesPerPixel, 6)
        XCTAssertEqual(advice(eight).thresholdPixels,
                       advice(config(megapixels: 42.2)).thresholdPixels)
    }

    func testNoAdviceBeforeImageInfoIsKnown() {
        XCTAssertNil(Config().keypointDivisorAdvice(physicalMemory: Self.iMacProMemory),
                     "with no dimensions there is no resolution to compare; the caller "
                     + "must say nothing rather than recommend a divisor")

        var noDepth = Config()
        noDepth.imageWidth = 7952
        noDepth.imageHeight = 5304
        XCTAssertNil(noDepth.keypointDivisorAdvice(physicalMemory: Self.iMacProMemory),
                     "and without the component depth there is no per-pixel cost either")
    }

    func testZeroPhysicalMemoryGivesNoAdvice() {
        XCTAssertNil(config(megapixels: 42.2).keypointDivisorAdvice(physicalMemory: 0))
    }

    // MARK: - The recommendation has to actually help

    /// Otherwise the advice is just a warning. Applying it should buy back most of the
    /// concurrency the frame size cost, which at 1.5 means roughly the 2.25x the scale
    /// space shrinks by.
    func testApplyingTheRecommendationBuysBackConcurrency() {
        let full = config(megapixels: 42.2)
        let a = advice(full)
        XCTAssertTrue(a.reduceRecommended)

        var reduced = full
        reduced.alignmentKeypointDetectionDivisor = a.recommendedDivisor

        let before = full.keypointConcurrency(physicalMemory: Self.iMacProMemory).limit
        let after = reduced.keypointConcurrency(physicalMemory: Self.iMacProMemory).limit
        XCTAssertGreaterThanOrEqual(after, before * 2,
                                    "1.5 shrinks the scale space by 2.25x, so it should "
                                    + "roughly double what fits in the same budget")

        // And it stays a recommendation, not a fix: 42MP is far enough past this machine
        // that even 1.5 does not get all 36 cores fed.
        XCTAssertLessThan(after, a.frameConcurrency)
    }
}
