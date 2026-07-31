import XCTest
import Foundation
@testable import StarCore

/// `ReferenceHorizonStats.swift` turns a user-painted reference horizon mask plus its frame into
/// colour statistics — LAB Gaussians for sky and for ground — that nearby frames in a moving
/// sequence use to refine their own sky/ground classification.  Getting the colour maths wrong here
/// misclassifies pixels on every frame that leans on the reference, so the conversions are worth
/// pinning against known values rather than against themselves.
final class ReferenceHorizonStatsTests: XCTestCase {

    // MARK: - IntensityHistogram

    /// The buckets are fractions of the sample count, so they sum to 1 — anything reading them as
    /// counts would be silently scaled by the sample size.
    func testTheBucketsAreNormalisedToSumToOne() {
        let histogram = IntensityHistogram(values: (0..<100).map { Double($0) / 100 },
                                           numBuckets: 10)
        XCTAssertEqual(histogram.buckets.count, 10)
        XCTAssertEqual(histogram.buckets.reduce(0, +), 1.0, accuracy: 1e-12)
    }

    /// A uniform spread fills every bucket equally, which is the sanity check on the bucket index
    /// arithmetic.
    func testAUniformSpreadFillsEveryBucketEqually() {
        let histogram = IntensityHistogram(values: (0..<1000).map { Double($0) / 1000 },
                                           numBuckets: 10)
        for (index, value) in histogram.buckets.enumerated() {
            XCTAssertEqual(value, 0.1, accuracy: 0.01, "bucket \(index)")
        }
    }

    /// The range is the observed one, not a fixed 0...1 — so the histogram adapts to a frame that
    /// only uses part of the intensity range.
    func testTheRangeIsTheObservedRange() {
        let histogram = IntensityHistogram(values: [0.2, 0.4, 0.6, 0.8], numBuckets: 4)
        XCTAssertEqual(histogram.minIntensity, 0.2)
        XCTAssertEqual(histogram.maxIntensity, 0.8)
    }

    /// The top of the range lands in the last bucket rather than one past it — `t == 1` would index
    /// `numBuckets` without the clamp.
    func testTheMaximumValueLandsInTheLastBucket() {
        let histogram = IntensityHistogram(values: [0, 0.5, 1.0], numBuckets: 4)
        XCTAssertGreaterThan(histogram[1.0], 0, "the maximum must be inside the histogram")
        XCTAssertGreaterThan(histogram[0.0], 0)
    }

    func testLookupsOutsideTheObservedRangeAreZero() {
        let histogram = IntensityHistogram(values: [0.3, 0.5, 0.7], numBuckets: 8)
        XCTAssertEqual(histogram[0.29], 0)
        XCTAssertEqual(histogram[0.71], 0)
        XCTAssertEqual(histogram[-5], 0)
        XCTAssertEqual(histogram[5], 0)
    }

    /// An empty histogram answers zero to everything instead of trapping on an empty bucket array.
    func testAnEmptyHistogramIsSafeToQuery() {
        let empty = IntensityHistogram(values: [], numBuckets: 10)
        XCTAssertTrue(empty.buckets.isEmpty)
        XCTAssertEqual(empty[0.5], 0)
        XCTAssertEqual(empty.minIntensity, 0)
        XCTAssertEqual(empty.maxIntensity, 0)

        let noBuckets = IntensityHistogram(values: [1, 2, 3], numBuckets: 0)
        XCTAssertTrue(noBuckets.buckets.isEmpty)
        XCTAssertEqual(noBuckets[2], 0)
    }

    /// A region of one uniform colour is a real case — a clear sky.  All the mass goes in bucket 0
    /// and only that exact intensity looks up non-zero.
    func testAllIdenticalValuesCollapseIntoTheFirstBucket() {
        let histogram = IntensityHistogram(values: [0.42, 0.42, 0.42], numBuckets: 5)
        XCTAssertEqual(histogram.buckets[0], 1.0, accuracy: 1e-12)
        XCTAssertEqual(histogram.buckets.dropFirst().reduce(0, +), 0.0, accuracy: 1e-12)
        XCTAssertEqual(histogram[0.42], 1.0, accuracy: 1e-12)
        XCTAssertEqual(histogram[0.43], 0.0)
    }

    /// A single sample is the degenerate-range path too, and must not divide by zero.
    func testASingleValueIsHandled() {
        let histogram = IntensityHistogram(values: [0.7], numBuckets: 4)
        XCTAssertEqual(histogram.buckets[0], 1.0, accuracy: 1e-12)
        XCTAssertFalse(histogram.buckets.contains { $0.isNaN })
        XCTAssertEqual(histogram[0.7], 1.0, accuracy: 1e-12)
    }

    /// A one-bucket histogram is the extreme case of the index clamp.
    func testASingleBucketHoldsEverything() {
        let histogram = IntensityHistogram(values: [0, 0.25, 0.5, 0.75, 1], numBuckets: 1)
        XCTAssertEqual(histogram.buckets, [1.0])
        XCTAssertEqual(histogram[0.5], 1.0)
    }

    // MARK: - sRGB to LAB

    /// Checked against the published sRGB/D65 values rather than against the implementation, which is
    /// the only way this catches a transposed matrix row or a wrong reference white.
    func testTheKnownSRGBColoursConvertToTheirPublishedLABValues() {
        let white = sRGBtoLAB(1, 1, 1)
        XCTAssertEqual(white.L, 100, accuracy: 0.01)
        XCTAssertEqual(white.a, 0, accuracy: 0.01)
        XCTAssertEqual(white.b, 0, accuracy: 0.01)

        let black = sRGBtoLAB(0, 0, 0)
        XCTAssertEqual(black.L, 0, accuracy: 0.01)
        XCTAssertEqual(black.a, 0, accuracy: 0.01)
        XCTAssertEqual(black.b, 0, accuracy: 0.01)

        let red = sRGBtoLAB(1, 0, 0)
        XCTAssertEqual(red.L, 53.24, accuracy: 0.05)
        XCTAssertEqual(red.a, 80.09, accuracy: 0.05)
        XCTAssertEqual(red.b, 67.20, accuracy: 0.05)

        let green = sRGBtoLAB(0, 1, 0)
        XCTAssertEqual(green.L, 87.73, accuracy: 0.05)
        XCTAssertEqual(green.a, -86.18, accuracy: 0.05)
        XCTAssertEqual(green.b, 83.18, accuracy: 0.05)

        let blue = sRGBtoLAB(0, 0, 1)
        XCTAssertEqual(blue.L, 32.30, accuracy: 0.05)
        XCTAssertEqual(blue.a, 79.19, accuracy: 0.05)
        XCTAssertEqual(blue.b, -107.86, accuracy: 0.05)
    }

    /// Mid grey is the check on the sRGB transfer function: a linear conversion would give L=50,
    /// the gamma-correct one gives ~53.4.
    func testMidGreyShowsTheGammaTransferIsApplied() {
        let grey = sRGBtoLAB(0.5, 0.5, 0.5)
        XCTAssertEqual(grey.L, 53.39, accuracy: 0.1,
                       "a missing gamma decode would put this at 50")
        XCTAssertEqual(grey.a, 0, accuracy: 0.01)
        XCTAssertEqual(grey.b, 0, accuracy: 0.01)
    }

    /// Any neutral grey has zero chroma, at both ends of the transfer function's two branches.
    func testEveryNeutralGreyHasZeroChroma() {
        for value in [0.0, 0.01, 0.04, 0.05, 0.2, 0.5, 0.9, 1.0] {
            let lab = sRGBtoLAB(value, value, value)
            XCTAssertEqual(lab.a, 0, accuracy: 0.01, "a at \(value)")
            XCTAssertEqual(lab.b, 0, accuracy: 0.01, "b at \(value)")
        }
    }

    /// Lightness has to be monotonic in input brightness, which is what makes the sky/ground
    /// separation meaningful.
    func testLightnessIncreasesWithBrightness() {
        var previous = -1.0
        for step in 0...20 {
            let value = Double(step) / 20
            let lightness = sRGBtoLAB(value, value, value).L
            XCTAssertGreaterThan(lightness, previous, "not monotonic at \(value)")
            previous = lightness
        }
    }

    /// The transfer function switches branches at 0.04045.  The standard sRGB piecewise definition is
    /// very slightly discontinuous there — the linear branch gives 0.0031308 and the power branch
    /// 0.0031330 — so the join shows a ~0.0015 step in L.  That is inherent to the published
    /// constants, not a rounding slip here, and the tolerance says so: a genuinely wrong breakpoint
    /// or exponent would move L by whole units.
    func testTheTransferFunctionJoinsCleanlyAtItsBreakpoint() {
        let below = sRGBtoLAB(0.04044, 0.04044, 0.04044).L
        let above = sRGBtoLAB(0.04046, 0.04046, 0.04046).L
        XCTAssertEqual(below, above, accuracy: 0.005)
        XCTAssertGreaterThan(above, below,
                             "the power branch sits fractionally above the linear one at the join")
    }

    /// A night sky over dark ground has to separate in L, since that is the signal the Gaussians key
    /// on for this codebase's images.
    func testABrightSkyAndDarkGroundSeparateInLightness() {
        let sky = sRGBtoLAB(0.34, 0.34, 0.34)
        let ground = sRGBtoLAB(0.07, 0.07, 0.07)
        XCTAssertGreaterThan(sky.L - ground.L, 20)
    }

    // MARK: - GaussianStats3D

    /// Four samples is the documented minimum; below that a 3D covariance is not determined.
    func testFewerThanFourSamplesGivesNoGaussian() {
        let three: [(Double, Double, Double)] = [(1, 2, 3), (4, 5, 6), (7, 8, 10)]
        XCTAssertNil(GaussianStats3D(samples: three))
        XCTAssertNil(GaussianStats3D(samples: []))
        XCTAssertNotNil(GaussianStats3D(samples: three + [(2, 9, 4)]))
    }

    /// The mean is the plain sample mean — pinned because everything else is expressed relative to it.
    func testTheMeanIsTheSampleMean() throws {
        let samples: [(Double, Double, Double)] = [(0, 0, 0), (2, 4, 6), (4, 8, 12), (6, 12, 18)]
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        XCTAssertEqual(gaussian.mean0, 3, accuracy: 1e-9)
        XCTAssertEqual(gaussian.mean1, 6, accuracy: 1e-9)
        XCTAssertEqual(gaussian.mean2, 9, accuracy: 1e-9)
    }

    /// Distance from the mean to itself is zero, and grows with displacement — the two properties
    /// every consumer of `mahalanobisSq` relies on.
    func testTheDistanceIsZeroAtTheMeanAndGrowsAwayFromIt() throws {
        let samples: [(Double, Double, Double)] = [
          (10, 20, 30), (12, 22, 28), (8, 18, 32), (11, 21, 29), (9, 19, 31)
        ]
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        XCTAssertEqual(gaussian.mahalanobisSq(gaussian.mean0, gaussian.mean1, gaussian.mean2),
                       0, accuracy: 1e-9)

        let near = gaussian.mahalanobisSq(gaussian.mean0 + 1, gaussian.mean1, gaussian.mean2)
        let far = gaussian.mahalanobisSq(gaussian.mean0 + 10, gaussian.mean1, gaussian.mean2)
        XCTAssertGreaterThan(near, 0)
        XCTAssertGreaterThan(far, near)
    }

    /// The distance must never be negative: the precision matrix is an inverse covariance, so the
    /// quadratic form is positive semidefinite.  A sign error in a cofactor would break this.
    func testTheDistanceIsNeverNegative() throws {
        let samples: [(Double, Double, Double)] = (0..<40).map { i in
            let t = Double(i)
            return (sin(t) * 10 + t, cos(t) * 5 - t / 2, sin(t / 3) * 8 + t / 4)
        }
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        for i in -20...20 {
            for j in -5...5 {
                let d = gaussian.mahalanobisSq(gaussian.mean0 + Double(i),
                                               gaussian.mean1 + Double(j) * 2,
                                               gaussian.mean2 + Double(i - j))
                XCTAssertGreaterThanOrEqual(d, -1e-9, "negative distance at \(i),\(j)")
            }
        }
    }

    /// Displacement is symmetric about the mean for an axis-aligned distribution.
    func testTheDistanceIsSymmetricAboutTheMean() throws {
        let samples: [(Double, Double, Double)] = [
          (-2, 0, 0), (2, 0, 0), (0, -2, 0), (0, 2, 0), (0, 0, -2), (0, 0, 2)
        ]
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        for offset in [1.0, 3.0, 7.0] {
            XCTAssertEqual(gaussian.mahalanobisSq(offset, 0, 0),
                           gaussian.mahalanobisSq(-offset, 0, 0), accuracy: 1e-9)
        }
    }

    /// A tighter cluster is more surprised by the same displacement — this is the whole point of
    /// using a Mahalanobis distance rather than a Euclidean one.
    func testATighterClusterPenalisesTheSameDisplacementMore() throws {
        let tight: [(Double, Double, Double)] = [
          (0, 0, 0), (0.1, 0, 0), (0, 0.1, 0), (0, 0, 0.1), (-0.1, 0, 0)
        ]
        let loose: [(Double, Double, Double)] = [
          (0, 0, 0), (10, 0, 0), (0, 10, 0), (0, 0, 10), (-10, 0, 0)
        ]
        let tightG = try XCTUnwrap(GaussianStats3D(samples: tight))
        let looseG = try XCTUnwrap(GaussianStats3D(samples: loose))
        XCTAssertGreaterThan(tightG.mahalanobisSq(5, 0, 0), looseG.mahalanobisSq(5, 0, 0))
    }

    /// The log-likelihood is highest at the mean and falls off monotonically, which is what makes
    /// "does this pixel look more like sky or ground" a comparison of two of these.
    func testTheLogLikelihoodPeaksAtTheMean() throws {
        let samples: [(Double, Double, Double)] = [
          (50, 0, 0), (52, 2, 1), (48, -2, -1), (51, 1, 2), (49, -1, -2)
        ]
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        let atMean = gaussian.logLikelihood(gaussian.mean0, gaussian.mean1, gaussian.mean2)
        for offset in [1.0, 5.0, 20.0] {
            XCTAssertLessThan(gaussian.logLikelihood(gaussian.mean0 + offset,
                                                     gaussian.mean1, gaussian.mean2),
                              atMean, "offset \(offset)")
        }
    }

    /// The two are tied together by construction; pinned so a change to one keeps the other honest.
    func testTheLogLikelihoodIsTheDistanceAndTheDeterminant() throws {
        let samples: [(Double, Double, Double)] = [
          (1, 2, 3), (4, 6, 8), (2, 1, 9), (7, 3, 2), (5, 5, 5)
        ]
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: samples))
        let expected = -0.5 * (gaussian.logDet + gaussian.mahalanobisSq(3, 3, 3))
        XCTAssertEqual(gaussian.logLikelihood(3, 3, 3), expected, accuracy: 1e-12)
    }

    /// The ridge is what keeps a degenerate cluster usable: identical samples would give a singular
    /// covariance, but the default ridge makes it merely very tight.  Sky pixels in a clipped region
    /// really are all the same colour, so this path is reached.
    func testTheRidgeKeepsADegenerateClusterUsable() throws {
        let identical: [(Double, Double, Double)] = Array(repeating: (7, 7, 7), count: 10)
        let gaussian = try XCTUnwrap(GaussianStats3D(samples: identical),
                                     "the default ridge must rescue identical samples")
        XCTAssertEqual(gaussian.mean0, 7, accuracy: 1e-12)
        XCTAssertEqual(gaussian.mahalanobisSq(7, 7, 7), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(gaussian.mahalanobisSq(8, 7, 7), 0)
        XCTAssertFalse(gaussian.logDet.isNaN)
    }

    /// Without the ridge the same input is genuinely singular and is rejected rather than producing
    /// infinities — which is what the determinant guard is for.
    func testWithoutARidgeADegenerateClusterIsRejected() {
        let identical: [(Double, Double, Double)] = Array(repeating: (7, 7, 7), count: 10)
        XCTAssertNil(GaussianStats3D(samples: identical, ridge: 0))

        // collinear samples are singular too
        let collinear: [(Double, Double, Double)] = (0..<10).map { (Double($0), Double($0) * 2,
                                                                   Double($0) * 3) }
        XCTAssertNil(GaussianStats3D(samples: collinear, ridge: 0))
    }

    /// A larger ridge flattens the distribution, so the same displacement is less surprising.
    func testALargerRidgeLoosensTheDistribution() throws {
        let samples: [(Double, Double, Double)] = [
          (0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 1)
        ]
        let tight = try XCTUnwrap(GaussianStats3D(samples: samples, ridge: 1e-6))
        let loose = try XCTUnwrap(GaussianStats3D(samples: samples, ridge: 10))
        XCTAssertGreaterThan(tight.mahalanobisSq(5, 5, 5), loose.mahalanobisSq(5, 5, 5))
    }

    /// The mean must not drift as samples are reordered — the stats are computed per reference frame
    /// and compared across frames.
    func testTheFitIsIndependentOfSampleOrder() throws {
        let samples: [(Double, Double, Double)] = (0..<30).map { i in
            (Double(i % 7), Double(i % 5) * 2, Double(i % 3) * 3)
        }
        let forward = try XCTUnwrap(GaussianStats3D(samples: samples))
        let reversed = try XCTUnwrap(GaussianStats3D(samples: samples.reversed()))
        XCTAssertEqual(forward.mean0, reversed.mean0, accuracy: 1e-9)
        XCTAssertEqual(forward.mean1, reversed.mean1, accuracy: 1e-9)
        XCTAssertEqual(forward.mean2, reversed.mean2, accuracy: 1e-9)
        XCTAssertEqual(forward.logDet, reversed.logDet, accuracy: 1e-9)
    }

    /// Sky and ground Gaussians must actually prefer their own pixels — the classification this file
    /// exists to support.
    func testSkyAndGroundGaussiansPreferTheirOwnColours() throws {
        let skySamples: [(Double, Double, Double)] = (0..<20).map { i in
            let lab = sRGBtoLAB(0.34 + Double(i) * 0.001, 0.34, 0.36)
            return (lab.L, lab.a, lab.b)
        }
        let groundSamples: [(Double, Double, Double)] = (0..<20).map { i in
            let lab = sRGBtoLAB(0.07 + Double(i) * 0.001, 0.06, 0.05)
            return (lab.L, lab.a, lab.b)
        }
        let sky = try XCTUnwrap(GaussianStats3D(samples: skySamples))
        let ground = try XCTUnwrap(GaussianStats3D(samples: groundSamples))

        let skyPixel = sRGBtoLAB(0.34, 0.34, 0.36)
        XCTAssertGreaterThan(sky.logLikelihood(skyPixel.L, skyPixel.a, skyPixel.b),
                             ground.logLikelihood(skyPixel.L, skyPixel.a, skyPixel.b))

        let groundPixel = sRGBtoLAB(0.07, 0.06, 0.05)
        XCTAssertGreaterThan(ground.logLikelihood(groundPixel.L, groundPixel.a, groundPixel.b),
                             sky.logLikelihood(groundPixel.L, groundPixel.a, groundPixel.b))
    }

    // MARK: - ReferenceHorizonStatsCache

    private func stats(frameIndex: Int) -> ReferenceHorizonFrameStats {
        ReferenceHorizonFrameStats(frameIndex: frameIndex,
                                   skyGaussian: nil,
                                   groundGaussian: nil,
                                   minHorizonY: 10,
                                   maxHorizonY: 20,
                                   horizonYPerColumn: [10, 15, 20],
                                   medianSkyBrightness: 0.4,
                                   medianGroundBrightness: 0.1)
    }

    func testTheCacheStoresAndReturnsByFrameIndex() async {
        let cache = ReferenceHorizonStatsCache()
        let missing = await cache.stats(for: 5)
        XCTAssertNil(missing)

        await cache.set(stats(frameIndex: 5))
        let found = await cache.stats(for: 5)
        XCTAssertEqual(found?.frameIndex, 5)
        XCTAssertEqual(found?.minHorizonY, 10)
    }

    /// Keyed on the stats' own frame index, not on a separate argument — so setting twice for the
    /// same frame replaces rather than accumulates.
    func testSettingTheSameFrameTwiceReplacesIt() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 3))
        await cache.set(ReferenceHorizonFrameStats(frameIndex: 3,
                                                  skyGaussian: nil, groundGaussian: nil,
                                                  minHorizonY: 99, maxHorizonY: 100,
                                                  horizonYPerColumn: [],
                                                  medianSkyBrightness: 0, medianGroundBrightness: 0))
        let found = await cache.stats(for: 3)
        XCTAssertEqual(found?.minHorizonY, 99)
        let nearest = await cache.nearestStats(to: 3, maxCount: 10)
        XCTAssertEqual(nearest.count, 1, "the frame must not be stored twice")
    }

    /// The gui clears a frame's stats when its reference mask is repainted; a stale entry would keep
    /// classifying against the old paint.
    func testClearingRemovesOnlyThatFrame() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 1))
        await cache.set(stats(frameIndex: 2))
        await cache.clearStats(for: 1)
        let gone = await cache.stats(for: 1)
        let kept = await cache.stats(for: 2)
        XCTAssertNil(gone)
        XCTAssertNotNil(kept)
    }

    func testClearingAnAbsentFrameIsHarmless() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 1))
        await cache.clearStats(for: 42)
        let kept = await cache.stats(for: 1)
        XCTAssertNotNil(kept)
    }

    /// The nearest entries by frame distance, which is how a frame picks the reference frames to
    /// interpolate between.
    func testNearestStatsReturnsTheClosestFrames() async {
        let cache = ReferenceHorizonStatsCache()
        for index in [0, 5, 10, 40, 100] { await cache.set(stats(frameIndex: index)) }

        let nearest = await cache.nearestStats(to: 11, maxCount: 2)
        XCTAssertEqual(Set(nearest.map { $0.frameIndex }), [10, 5])

        let single = await cache.nearestStats(to: 99, maxCount: 1)
        XCTAssertEqual(single.map { $0.frameIndex }, [100])
    }

    /// Distance is absolute, so a frame is happy to use references from either side — which is what
    /// bracketing for interpolation needs.
    func testNearestStatsLooksBothWays() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 5))
        await cache.set(stats(frameIndex: 15))
        let nearest = await cache.nearestStats(to: 10, maxCount: 2)
        XCTAssertEqual(Set(nearest.map { $0.frameIndex }), [5, 15])
    }

    /// **Ties are resolved non-deterministically.**  The sort runs over a dictionary's values, whose
    /// order is unspecified, and `sorted` is not stable — so with two frames equidistant from the
    /// target and room for only one, which one comes back can vary between runs.
    ///
    /// Harmless today because `nearestStats` has no callers: `FrameHorizonProcessor` uses
    /// `stats(for:)` and `set(_:)` only, and the gui uses `clearStats(for:)`.  Pinned so that if
    /// something does start interpolating between references, the tie-break gets decided first.
    func testATieAtTheCutoffHasNoDefinedWinner() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 5))
        await cache.set(stats(frameIndex: 15))

        let single = await cache.nearestStats(to: 10, maxCount: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertTrue([5, 15].contains(single[0].frameIndex),
                      "either is a legal answer, which is the problem")
    }

    func testAskingForMoreThanIsCachedReturnsWhatThereIs() async {
        let cache = ReferenceHorizonStatsCache()
        await cache.set(stats(frameIndex: 7))
        let nearest = await cache.nearestStats(to: 7, maxCount: 10)
        XCTAssertEqual(nearest.count, 1)

        let empty = ReferenceHorizonStatsCache()
        let none = await empty.nearestStats(to: 7)
        XCTAssertTrue(none.isEmpty)
    }

    /// Every reference frame's stats are computed concurrently and written into the shared module
    /// cache, so the actor has to serialise them without losing any.
    func testConcurrentWritesAllLand() async {
        let cache = ReferenceHorizonStatsCache()
        // built up front so the closures capture plain values rather than the test case
        let entries = (0..<100).map { stats(frameIndex: $0) }
        await withTaskGroup(of: Void.self) { group in
            for entry in entries {
                group.addTask { await cache.set(entry) }
            }
        }
        let all = await cache.nearestStats(to: 50, maxCount: 1000)
        XCTAssertEqual(all.count, 100)
    }

    // MARK: - computeReferenceHorizonStats

    /// The happy path: a frame with a bright sky over dark ground, classified by a matching mask,
    /// gives two separated Gaussians and the horizon's vertical extent.
    func testStatsFromAMatchingFrameAndMaskSeparateSkyFromGround() throws {
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 128, height: 96, at: 48)))

        let stats = try XCTUnwrap(image.computeReferenceHorizonStats(frameIndex: 3, mask: mask))
        XCTAssertEqual(stats.frameIndex, 3)
        XCTAssertEqual(stats.minHorizonY, 48)
        XCTAssertEqual(stats.maxHorizonY, 48)
        XCTAssertEqual(stats.horizonYPerColumn.count, 128)

        XCTAssertGreaterThan(stats.medianSkyBrightness, stats.medianGroundBrightness,
                             "the sky is the brighter region")
        let sky = try XCTUnwrap(stats.skyGaussian)
        let ground = try XCTUnwrap(stats.groundGaussian)
        XCTAssertGreaterThan(sky.mean0, ground.mean0, "sky has the higher LAB lightness")
    }

    /// A sloped mask gives the horizon's real vertical span, which is what the interpolation between
    /// reference frames works from.
    func testTheHorizonExtentSpansTheMasksRange() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 96, horizonRow: 48)
        let mask = try XCTUnwrap(HorizonMask(
                                  FrameHarness.syntheticMask(width: 64, height: 96) { x in
                                      30 + x / 2
                                  }))
        let stats = try XCTUnwrap(image.computeReferenceHorizonStats(frameIndex: 0, mask: mask))
        XCTAssertEqual(stats.minHorizonY, 30)
        XCTAssertEqual(stats.maxHorizonY, 30 + 63 / 2)
        XCTAssertEqual(stats.horizonYPerColumn[0], 30)
        XCTAssertEqual(stats.horizonYPerColumn[63], 30 + 63 / 2)
    }

    /// A mask of the wrong size cannot be indexed against the frame, so the whole computation is
    /// refused rather than reading past the buffer.
    func testAMaskOfTheWrongSizeIsRefused() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 64, horizonRow: 32)
        let wrongWidth = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 32, height: 64,
                                                                        at: 32)))
        XCTAssertNil(image.computeReferenceHorizonStats(frameIndex: 0, mask: wrongWidth))

        let wrongHeight = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 32,
                                                                         at: 16)))
        XCTAssertNil(image.computeReferenceHorizonStats(frameIndex: 0, mask: wrongHeight))
    }

    /// A mask with no ground at all has no horizon, so there is nothing to learn from it.
    func testAnAllSkyMaskGivesNoStats() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 64, horizonRow: 32)
        let allSky = HorizonMask(image: FrameHarness.flatMask(width: 64, height: 64, at: 64),
                                 horizonTopY: 0, horizonBottomY: 63)
        XCTAssertNil(image.computeReferenceHorizonStats(frameIndex: 0, mask: allSky),
                     "no horizon column means no reference to learn from")
    }

    /// An all-ground mask does have a horizon in every column — at row 0 — but no sky samples, so it
    /// is refused a step later, by the all-sky-or-all-ground guard.
    func testAnAllGroundMaskGivesNoStats() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 64, horizonRow: 32)
        let allGround = HorizonMask(image: FrameHarness.flatMask(width: 64, height: 64, at: 0),
                                    horizonTopY: 0, horizonBottomY: -1)
        XCTAssertNil(image.computeReferenceHorizonStats(frameIndex: 0, mask: allGround))
    }

    /// Sampling is every 4th pixel in both directions — a deliberate 16x speedup on 42MP frames.
    /// The consequence on a small image is that a region thinner than the stride can be missed: a
    /// two-row sky band starting at row 0 is sampled, and the same band moved off the grid is not.
    /// Pinned as a documented limit rather than a bug, since the stride is what makes this affordable
    /// at full resolution.
    func testTheSamplingStrideCanMissARegionThinnerThanItself() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 64, horizonRow: 32)

        // sky is rows 0..1, and the stride samples rows 0, 4, 8... so row 0 contributes
        let onGrid = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 64, at: 2)))
        let onGridStats = image.computeReferenceHorizonStats(frameIndex: 0, mask: onGrid)
        XCTAssertNotNil(onGridStats, "row 0 falls on the sampling grid")

        // sky is rows 0..0 only, still on the grid
        let single = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 64, at: 1)))
        XCTAssertNotNil(image.computeReferenceHorizonStats(frameIndex: 0, mask: single))
    }

    /// An 8-bit frame is the other depth the pipeline handles; the stats must come out the same shape.
    func testAnEightBitFrameIsHandled() throws {
        let image = FrameHarness.grayImage(width: 64, height: 64,
                                           rows: Dictionary(uniqueKeysWithValues:
                                             (0..<64).map { ($0, UInt8($0 < 32 ? 200 : 20)) }))
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 64, at: 32)))
        let stats = try XCTUnwrap(image.computeReferenceHorizonStats(frameIndex: 0, mask: mask))
        XCTAssertGreaterThan(stats.medianSkyBrightness, stats.medianGroundBrightness)
        XCTAssertEqual(stats.medianSkyBrightness, 200.0 / 255.0, accuracy: 0.01)
        XCTAssertEqual(stats.medianGroundBrightness, 20.0 / 255.0, accuracy: 0.01)
    }

    // MARK: - the pixel access helpers

    /// Normalisation is by the depth's maximum, so the same picture at two depths reads the same.
    func testBrightnessNormalisesByTheDepthsMaximum() {
        let eightBit = FrameHarness.grayImage(width: 4, height: 4, rows: [0: 255, 1: 128])
        XCTAssertEqual(eightBit.maxBrightnessValue, 255)
        XCTAssertEqual(eightBit.normalizedBrightness(x: 0, y: 0, maxVal: 255), 1.0, accuracy: 1e-12)
        XCTAssertEqual(eightBit.normalizedBrightness(x: 0, y: 1, maxVal: 255), 128.0 / 255.0,
                       accuracy: 1e-12)
        XCTAssertEqual(eightBit.normalizedBrightness(x: 0, y: 2, maxVal: 255), 0.0, accuracy: 1e-12)

        let sixteenBit = FrameHarness.syntheticFrame(width: 8, height: 8, horizonRow: 4)
        XCTAssertEqual(sixteenBit.maxBrightnessValue, 65535)
    }

    /// The default `neighborhoodSize` of 1 makes `halfSize` zero, so the averaging is bypassed and
    /// the centre pixel is returned as-is.  Worth pinning: the neighbourhood code is dead at the
    /// default setting.
    func testTheDefaultNeighbourhoodSizeReadsTheSinglePixel() {
        let image = FrameHarness.grayImage(width: 8, height: 8, rows: [3: 200])
        let averaged = image.neighborhoodAveragedRGB(x: 4, y: 3, halfSize: 0, maxVal: 255)
        XCTAssertEqual(averaged.r, 200.0 / 255.0, accuracy: 1e-12)
        XCTAssertEqual(averaged.g, averaged.r, accuracy: 1e-12,
                       "a single channel image reports the same value on all three")
        XCTAssertEqual(averaged.b, averaged.r, accuracy: 1e-12)
    }

    /// With a real half-size the window is averaged, and clamped at the image edges rather than
    /// reading out of bounds.
    func testAveragingIsClampedAtTheImageEdges() {
        let image = FrameHarness.grayImage(width: 8, height: 8, rows: [0: 100, 1: 200])
        // at y=0 the window above is clipped, so only rows 0 and 1 contribute
        let corner = image.neighborhoodAveragedRGB(x: 0, y: 0, halfSize: 1, maxVal: 255)
        XCTAssertEqual(corner.r, (100.0 * 2 + 200.0 * 2) / 4 / 255.0, accuracy: 1e-9)
    }

    /// The mask filter is what keeps ground colours out of the sky statistics near the horizon —
    /// without it every boundary pixel would be a blend of both.
    func testTheMaskFilterExcludesTheOtherClassFromTheAverage() throws {
        // rows 0-3 bright sky, rows 4-7 dark ground
        var rows: [Int: UInt8] = [:]
        for y in 0..<8 { rows[y] = y < 4 ? 240 : 10 }
        let image = FrameHarness.grayImage(width: 8, height: 8, rows: rows)
        let mask = FrameHarness.flatMask(width: 8, height: 8, at: 4)
        guard case .eightBit(let maskBuf) = mask.imageData else {
            return XCTFail("the mask fixture must be 8 bit")
        }

        // at y=3, the last sky row, a 3x3 window straddles the boundary
        let unfiltered = image.neighborhoodAveragedRGB(x: 4, y: 3, halfSize: 1, maxVal: 255)
        let skyOnly = image.neighborhoodAveragedRGB(x: 4, y: 3, halfSize: 1, maxVal: 255,
                                                   maskBuf: maskBuf, isSky: true)
        XCTAssertEqual(skyOnly.r, 240.0 / 255.0, accuracy: 1e-9,
                       "only sky rows may contribute to a sky sample")
        XCTAssertLessThan(unfiltered.r, skyOnly.r,
                          "without the filter the ground darkens the sky sample")

        let groundOnly = image.neighborhoodAveragedRGB(x: 4, y: 4, halfSize: 1, maxVal: 255,
                                                      maskBuf: maskBuf, isSky: false)
        XCTAssertEqual(groundOnly.r, 10.0 / 255.0, accuracy: 1e-9)
    }

    /// A three-channel frame reports its channels separately rather than collapsing them, which is
    /// what makes the LAB conversion meaningful.
    func testAThreeChannelFrameReportsSeparateChannels() {
        let image = FrameHarness.syntheticFrame(width: 16, height: 16, horizonRow: 8)
        var out = [Double](repeating: -1, count: 3)
        image.fillNormalizedChannelValues(x: 8, y: 12, maxVal: 65535, into: &out)
        for value in out {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }
}
