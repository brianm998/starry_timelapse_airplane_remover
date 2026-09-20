import XCTest
@testable import StarCppBridge

/// Coverage for the from-scratch AKAZE port in `AKAZEDetector.cpp` — the
/// earth/ground counterpart to `SIFTDetectorTests.swift`'s SIFT coverage. See
/// that file's header and `Config.useGPUForAKAZE`'s doc comment for why this
/// exists at all (OpenCV's real AKAZE internals are not exposed by any public
/// API either, so there is no seam to hand a GPU-built pyramid into "OpenCV's
/// real AKAZE" for the rest of the pipeline).
///
/// Same two questions as the SIFT suite, tested separately:
///
///   1. Does the ported algorithm (nonlinear diffusion pyramid math aside,
///      everything else — extrema, subpixel refinement, orientation, MLDB
///      descriptor) match real cv::AKAZE at all? `debugAkazeReference` builds
///      its pyramid with real cv::GaussianBlur/cv::Scharr/cv::resize calls, so
///      any disagreement here is about the ported algorithm, not about Metal.
///   2. Does building the same pyramid on the GPU change anything further?
///      `debugAkazeGPU` uses the exact same ported algorithm, only the
///      pyramid construction differs.
///
/// All three go through `ia_debug_akaze_{reference,gpu,opencv}` directly,
/// bypassing `ia_find_features`'s CLAHE/mask/scale preprocessing entirely —
/// unchanged, existing, and not what this suite is testing. `ia_debug_akaze_opencv`
/// mirrors this codebase's own earth branch shape (detect, cap by response,
/// then describe) rather than a single detectAndCompute call, since that is
/// what the ported functions are actually being compared against.
final class AKAZEDetectorTests: XCTestCase {

    // MARK: - synthetic ground-like texture

    /// A textured field of hard-edged disks at deterministic (seeded)
    /// positions and varying radius, the same generator shape
    /// `SIFTDetectorTests.makeStarField` uses and for the same reason: a flat
    /// or smoothly-varying image gives a Hessian-determinant detector nothing
    /// to find, so this deliberately uses sharp edges and a spread of sizes.
    private func makeTexturedField(width: Int, height: Int, count: Int,
                                   seed: UInt64 = 1) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 40, count: width * height)

        for _ in 0..<count {
            let cx = Int(rng.nextUInt32() % UInt32(width))
            let cy = Int(rng.nextUInt32() % UInt32(height))
            let radius = 5 + Int(rng.nextUInt32() % 20)  // 5...24
            let r2 = radius * radius
            let bright = UInt8(180 + rng.nextUInt32() % 76)  // 180...255

            for dy in -radius...radius {
                for dx in -radius...radius {
                    guard dx * dx + dy * dy <= r2 else { continue }
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    pixels[y * width + x] = bright
                }
            }
        }

        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        data.update(from: pixels, count: width * height)
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    // MARK: - matching keypoint sets by position (same shape as SIFTDetectorTests)

    private func matchPositions(_ a: [(x: Double, y: Double)], _ b: [(x: Double, y: Double)],
                                tolerance: Double) -> (matched: Int, onlyA: Int, onlyB: Int, maxDelta: Double) {
        var usedB = Set<Int>()
        var matched = 0
        var maxDelta = 0.0
        for pa in a {
            var bestIdx = -1
            var bestDist = Double.greatestFiniteMagnitude
            for (j, pb) in b.enumerated() where !usedB.contains(j) {
                let d = (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)
                if d < bestDist { bestDist = d; bestIdx = j }
            }
            if bestIdx >= 0, bestDist.squareRoot() <= tolerance {
                usedB.insert(bestIdx)
                matched += 1
                maxDelta = max(maxDelta, bestDist.squareRoot())
            }
        }
        return (matched, a.count - matched, b.count - matched, maxDelta)
    }

    /// The threshold this codebase actually uses in production
    /// (ImageAligner.cpp's `earthDetectorThreshold`) — see its long comment
    /// for why 1e-4, not AKAZE's own 1e-3 default or 1e-5 floor.
    private let productionThreshold: Float = 1e-4

    // MARK: - tests

    /// The core claim: the ported algorithm, run with a real-OpenCV-built
    /// pyramid, finds essentially the same ground features as real cv::AKAZE.
    ///
    /// Measured on this synthetic field: 501/501 matched, maxDelta 0.0 — an
    /// exact match, better than SIFT's own reference-vs-real bar (~85%). That
    /// tracks: AKAZE's extrema search only needs the *ranking* of
    /// Hessian-determinant responses preserved, and this field's disks are
    /// large, high-contrast and well separated, so there is no near-tie for
    /// the identical real-cv::GaussianBlur/Scharr/resize pyramid math on both
    /// sides to disturb. 95% leaves margin below that measurement without the
    /// test being a rubber stamp.
    func testReferencePortAgreesWithRealAKAZEOnASyntheticField() throws {
        let img = makeTexturedField(width: 512, height: 384, count: 60)

        let real = try XCTUnwrap(ImageAligner.debugAkazeOpenCV(img, mask: nil, maxKeypoints: 500,
                                                               threshold: productionThreshold))
        let mine = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 500,
                                                                  threshold: productionThreshold))

        XCTAssertGreaterThan(real.keypointCount, 0, "the textured field itself has to yield keypoints")

        let (matched, onlyReal, onlyMine, maxDelta) = matchPositions(
          real.keypointPositions(), mine.keypointPositions(), tolerance: 1.5)

        XCTAssertGreaterThanOrEqual(matched, Int(Double(real.keypointCount) * 0.95),
                                    "only \(matched) of \(real.keypointCount) real keypoints had a "
                                    + "close match in the ported algorithm's output "
                                    + "(unmatched: \(onlyReal) real-only, \(onlyMine) mine-only)")
        XCTAssertLessThanOrEqual(maxDelta, 1.5, "matched keypoints should agree to well under a pixel")
    }

    /// Descriptor shape has to match exactly: 61 bytes (486-bit full MLDB,
    /// 3 channels), CV_8U, one row per keypoint.
    func testReferencePortDescriptorsHaveMLDBsShape() throws {
        let img = makeTexturedField(width: 256, height: 256, count: 30)
        let mine = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 200,
                                                                  threshold: productionThreshold))

        XCTAssertGreaterThan(mine.keypointCount, 0)
        XCTAssertEqual(mine.descriptorRows, mine.keypointCount)
        XCTAssertEqual(mine.descriptorCols, 61)
    }

    /// `maxKeypoints` caps the set the same way for both: KeyPointsFilter::retainBest
    /// is real OpenCV, called directly by the port, not reimplemented.
    func testMaxKeypointsCapIsHonoured() throws {
        let img = makeTexturedField(width: 512, height: 384, count: 80)
        let uncapped = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 0,
                                                                      threshold: productionThreshold))
        let capped = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 10,
                                                                    threshold: productionThreshold))

        XCTAssertGreaterThan(uncapped.keypointCount, 20,
                             "need well more than the cap's raw keypoints for the cap to mean anything")
        XCTAssertLessThanOrEqual(capped.keypointCount, 15,
                                 "retainBest(10) let far more than ties-at-the-cutoff through")
        XCTAssertLessThan(capped.keypointCount, uncapped.keypointCount)
    }

    /// A mask has to actually exclude keypoints outside it — real
    /// KeyPointsFilter::runByPixelsMask, called directly.
    func testAMaskExcludesKeypointsOutsideIt() throws {
        let width = 512, height = 384
        let img = makeTexturedField(width: width, height: height, count: 80)

        let maskData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width {
                maskData[y * width + x] = x < width / 2 ? 255 : 0
            }
        }
        let mask = MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                              bytesPerRow: width, data: UnsafeMutableRawPointer(maskData),
                              takeOwnership: true)

        let result = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: mask, maxKeypoints: 0,
                                                                    threshold: productionThreshold))
        XCTAssertGreaterThan(result.keypointCount, 0)
        for (x, _) in result.keypointPositions() {
            XCTAssertLessThan(x, Double(width) / 2, "a keypoint at x=\(x) survived a mask over the right half")
        }
    }

    // MARK: - GPU pyramid, when available

    /// The GPU-pyramid backend runs the identical ported algorithm on a
    /// GPU-built pyramid instead of a real-OpenCV one — isolating what the
    /// GPU pyramid changes from what the algorithm port itself changes
    /// (covered above). Skipped, not failed, with no GPU handler registered.
    ///
    /// The bar is measured, not assumed. Measured on this synthetic field:
    /// 484/501 matched (~96.6%), maxDelta ~1.6px — markedly closer than SIFT's
    /// own GPU-vs-reference bar (~83%), despite this pyramid leaning on more
    /// approximations (MPSImageGaussianBlur for both blurs, a clamp-to-edge
    /// Scharr instead of reflect-101, chained across 16 levels instead of
    /// SIFT's per-octave-independent ones). The likely reason is the same one
    /// that made the reference port match real AKAZE exactly above: only the
    /// *ranking* of Hessian-determinant responses has to survive, and this
    /// field's features are large and well separated. 90% leaves margin below
    /// the measurement without the test being a rubber stamp.
    func testGPUPyramidAgreesWithTheReferencePyramid() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        try XCTSkipUnless(gpu_ops_akaze_pyramid_available(), "no GPU AKAZE pyramid handler registered")

        let img = makeTexturedField(width: 512, height: 384, count: 60)

        let reference = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 500,
                                                                       threshold: productionThreshold))
        let gpu = try XCTUnwrap(ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 500,
                                                           threshold: productionThreshold))

        XCTAssertGreaterThan(gpu.keypointCount, 0, "the GPU pyramid path found no keypoints at all")

        let (matched, onlyRef, onlyGPU, maxDelta) = matchPositions(
          reference.keypointPositions(), gpu.keypointPositions(), tolerance: 2.0)

        XCTAssertGreaterThanOrEqual(matched, Int(Double(reference.keypointCount) * 0.90),
                                    "only \(matched) of \(reference.keypointCount) reference keypoints "
                                    + "matched the GPU pyramid's output (unmatched: \(onlyRef) "
                                    + "reference-only, \(onlyGPU) GPU-only)")
        XCTAssertLessThanOrEqual(maxDelta, 2.0)
    }
}

/// A small, fast, deterministic PRNG — matches SIFTDetectorTests's own copy;
/// duplicated rather than shared across two test targets in the same file for
/// the same reason SIFTDetector.cpp duplicates `wrapReadOnly`.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUInt32() -> UInt32 { UInt32(truncatingIfNeeded: nextUInt64()) }
}
