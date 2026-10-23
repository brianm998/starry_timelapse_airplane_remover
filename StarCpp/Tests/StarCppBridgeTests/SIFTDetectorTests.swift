import XCTest
@testable import StarCppBridge

/// Coverage for the from-scratch SIFT port in `SIFTDetector.cpp` — see its file
/// header and `Config.useGPUForSIFT`'s doc comment for why it exists at all
/// (OpenCV's real SIFT internals are not exposed by any public API, so there is
/// no seam to hand a GPU-built pyramid into "OpenCV's real SIFT" for the rest).
///
/// Two questions, tested separately:
///
///   1. Does the ported algorithm (extrema refinement, orientation, descriptor)
///      match real cv::SIFT at all? `debugSiftReference` builds its Gaussian
///      pyramid with real `cv::resize`/`cv::GaussianBlur` calls, so any
///      disagreement here is about the ported algorithm, not about Metal.
///   2. Does building the same pyramid on the GPU change anything further?
///      `debugSiftGPU` uses the exact same ported algorithm, only the pyramid
///      construction differs.
///
/// All three go through `ia_debug_sift_{reference,gpu,opencv}` directly,
/// bypassing `ia_find_features`'s mask/scale preprocessing entirely — that
/// preprocessing is unchanged, existing, and not what this suite is testing.
final class SIFTDetectorTests: XCTestCase {

    // MARK: - synthetic star field

    /// A dark frame with `count` sharp-edged bright disks of varying radius at
    /// deterministic (seeded) positions. Flat or smoothly-Gaussian images give
    /// SIFT little or nothing to find — a soft blob's contrast washes out in
    /// the scale-space blur before it ever becomes a extremum (see the
    /// `ReRunSkipTests.swift` comment this codebase already has on synthetic
    /// frames yielding no SIFT features at any size) — so this deliberately
    /// uses hard edges and a spread of sizes, the same reason a checkerboard
    /// is the standard corner-detector test pattern.
    private func makeStarField(width: Int, height: Int, count: Int,
                               seed: UInt64 = 1) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 4, count: width * height)

        for _ in 0..<count {
            let cx = Int(rng.nextUInt32() % UInt32(width))
            let cy = Int(rng.nextUInt32() % UInt32(height))
            let radius = 4 + Int(rng.nextUInt32() % 14)  // 4...17
            let r2 = radius * radius

            for dy in -radius...radius {
                for dx in -radius...radius {
                    guard dx * dx + dy * dy <= r2 else { continue }
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    pixels[y * width + x] = 250
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

    // MARK: - matching keypoint sets by position

    /// Greedy nearest-neighbour matching between two position sets, each point
    /// used at most once. Returns (matched pairs within `tolerance`, unmatched
    /// count on each side) — the shape a "did these two detectors find the same
    /// stars" comparison actually needs, since neither detector guarantees the
    /// same *order*.
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

    // MARK: - tests

    /// The core claim: the ported algorithm, run with a real-OpenCV-blurred
    /// pyramid, finds essentially the same stars as real cv::SIFT. Not exact —
    /// this is an independent implementation of extrema refinement, not a
    /// call into OpenCV's — but the overlap should be near total on an image
    /// with well-separated, unambiguous point sources.
    func testReferencePortAgreesWithRealSIFTOnASyntheticStarField() throws {
        let img = makeStarField(width: 512, height: 384, count: 40)

        let real = try XCTUnwrap(ImageAligner.debugSiftOpenCV(img, mask: nil, nfeatures: 500))
        let mine = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 500))

        XCTAssertGreaterThan(real.keypointCount, 0, "the star field itself has to yield keypoints")

        let (matched, onlyReal, onlyMine, maxDelta) = matchPositions(
          real.keypointPositions(), mine.keypointPositions(), tolerance: 1.5)

        // Every real bright, well-separated star should produce a matching
        // keypoint in both detectors at essentially the same position (SIFT's
        // own sub-pixel precision is well under a pixel); this is intentionally
        // a strict bar because the whole point of this test is to catch the
        // port disagreeing with real SIFT, not to rubber-stamp it.
        XCTAssertGreaterThanOrEqual(matched, Int(Double(real.keypointCount) * 0.85),
                                    "only \(matched) of \(real.keypointCount) real keypoints had a "
                                    + "close match in the ported algorithm's output "
                                    + "(unmatched: \(onlyReal) real-only, \(onlyMine) mine-only)")
        XCTAssertLessThanOrEqual(maxDelta, 1.5, "matched keypoints should agree to well under a pixel")
    }

    /// Descriptor shape has to match exactly regardless of content agreement:
    /// 128 columns (SIFT_DESCR_WIDTH^2 * SIFT_DESCR_HIST_BINS), CV_32F, one row
    /// per keypoint. A mismatch here would break every downstream matcher.
    func testReferencePortDescriptorsHaveSIFTsShape() throws {
        let img = makeStarField(width: 256, height: 256, count: 20)
        let mine = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 200))

        XCTAssertGreaterThan(mine.keypointCount, 0)
        XCTAssertEqual(mine.descriptorRows, mine.keypointCount)
        XCTAssertEqual(mine.descriptorCols, 128)
    }

    /// `nfeatures` caps the set the same way for both: KeyPointsFilter::retainBest
    /// is real OpenCV, called directly by the port, not reimplemented. Real
    /// `retainBest` can keep slightly more than requested when several
    /// keypoints tie exactly at the cutoff response (it keeps every tie, not
    /// an arbitrary subset of them) — this synthetic field's identical disks
    /// make that likely, so the bar is "capped substantially below uncapped,"
    /// not "capped to exactly n."
    func testNFeaturesCapIsHonoured() throws {
        let img = makeStarField(width: 512, height: 384, count: 60)
        let uncapped = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 0))
        let capped = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 10))

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
        let img = makeStarField(width: width, height: height, count: 60)

        // Block out the right half of the frame.
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

        let result = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: mask, nfeatures: 0))
        XCTAssertGreaterThan(result.keypointCount, 0)
        for (x, _) in result.keypointPositions() {
            XCTAssertLessThan(x, Double(width) / 2, "a keypoint at x=\(x) survived a mask over the right half")
        }
    }

    /// The cap is applied to what the mask allows, not to the whole frame first. cv::SIFT (and this
    /// port, before) kept the strongest N of the frame and then dropped those outside the mask,
    /// so a mask over a minority of the frame lost most of the cap: asked for 40 keypoints under
    /// a mask over the left quarter, it returned only the few of the frame's top 40 that happened to
    /// sit there. Now it returns the strongest 40 inside the mask.
    func testTheCapKeepsTheStrongestKeypointsInsideTheMask() throws {
        let width = 640, height = 480
        let img = makeNightSky(width: width, height: height, stars: 700)

        let maskData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height { for x in 0..<width { maskData[y * width + x] = x < width / 4 ? 255 : 0 } }
        let mask = MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                              bytesPerRow: width, data: UnsafeMutableRawPointer(maskData), takeOwnership: true)

        let uncapped = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: mask, nfeatures: 0))
        let cap = 40
        XCTAssertGreaterThan(uncapped.keypointCount, cap * 2, "the masked quarter needs enough keypoints for a cap to bind")
        let capped = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: mask, nfeatures: Int32(cap)))
        XCTAssertGreaterThanOrEqual(capped.keypointCount, cap, "the cap was spent outside the mask")
        XCTAssertLessThanOrEqual(capped.keypointCount, cap + 5, "ties at the cutoff only")
        for (x, _) in capped.keypointPositions() {
            XCTAssertLessThan(x, Double(width) / 4)
        }
    }

    /// A feature file is written beside its destination and renamed into place: afterwards the
    /// directory holds the one file, it reads back with the same keypoints, and writing again
    /// replaces it.
    func testFeatureFilesAreWrittenAtomically() throws {
        let img = makeStarField(width: 256, height: 192, count: 30)
        let features = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 200))
        XCTAssertGreaterThan(features.keypointCount, 0)

        let dir = NSTemporaryDirectory() + "features-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/keypoints_0.yml"

        XCTAssertTrue(features.write(toFilename: path))
        XCTAssertTrue(features.write(toFilename: path), "writing over an existing file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["keypoints_0.yml"],
                       "a temp file was left behind")
        let back = try XCTUnwrap(OCVFeatureSet.load(fromFilename: path))
        XCTAssertEqual(back.keypointCount, features.keypointCount)
    }

    /// The port against real cv::SIFT on the kind of image the sky detector is
    /// actually handed — see `makeNightSky`. The disks above are too large and
    /// too hard-edged to exercise the small scales stars live at, which is where
    /// a pyramid error shows; this is where it would.
    func testReferencePortAgreesWithRealSIFTOnARealisticNightSky() throws {
        let img = makeNightSky(width: 640, height: 480, stars: 700)

        let real = try XCTUnwrap(ImageAligner.debugSiftOpenCV(img, mask: nil, nfeatures: 2000))
        let mine = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 2000))
        assertSameKeypoints(mine, as: real, what: "the reference port")
    }

    // MARK: - GPU pyramid, when available

    /// The GPU-pyramid backend runs the identical ported algorithm on a
    /// GPU-built pyramid instead of a real-cv::GaussianBlur one — this isolates
    /// what the GPU pyramid changes from what the algorithm port itself
    /// changes (covered above). Skipped, not failed, with no GPU handler
    /// registered — matching this file's other GPU-dependent tests.
    ///
    /// The GPU pyramid blurs with cv::GaussianBlur's own coefficients and borders
    /// (see `buildSiftPyramid` in GPUOps.swift), so it is held to the same bar as
    /// the reference port, not a lower one. It used to be held to 70% here,
    /// against a measured ~83% that was put down to `MPSImageGaussianBlur` being
    /// documented as approximate. That approximation was the bug: on real moonlit
    /// frames it cost 41% of the keypoints.
    func testGPUPyramidAgreesWithTheReferencePyramid() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")

        let img = makeStarField(width: 512, height: 384, count: 40)

        let reference = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 500))
        let gpu = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 500))

        XCTAssertGreaterThan(gpu.keypointCount, 0, "the GPU pyramid path found no keypoints at all")

        let (matched, onlyRef, onlyGPU, maxDelta) = matchPositions(
          reference.keypointPositions(), gpu.keypointPositions(), tolerance: 1.5)

        XCTAssertGreaterThanOrEqual(matched, Int(Double(reference.keypointCount) * 0.98),
                                    "only \(matched) of \(reference.keypointCount) reference keypoints "
                                    + "matched the GPU pyramid's output (unmatched: \(onlyRef) "
                                    + "reference-only, \(onlyGPU) GPU-only)")
        XCTAssertLessThanOrEqual(maxDelta, 0.5)
    }

    /// Pyramid textures are pooled between builds. A reused texture carries the previous
    /// build's pixels, so this pins that nothing reads one before writing it: a second build
    /// of the same image, entirely on recycled textures, must find exactly the same keypoints.
    func testRecycledPyramidTexturesGiveTheSameKeypoints() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")

        let a = makeNightSky(width: 512, height: 384, stars: 400, seed: 11)
        let b = makeNightSky(width: 512, height: 384, stars: 400, seed: 23)   // different pixels, same sizes

        GPUOps.trimTexturePool()
        let first = try XCTUnwrap(ImageAligner.debugSiftGPU(a, mask: nil, nfeatures: 1000))
        let missesAfterFirst = GPUOps.texturePoolStats.misses
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(b, mask: nil, nfeatures: 1000))   // dirties the pool
        let again = try XCTUnwrap(ImageAligner.debugSiftGPU(a, mask: nil, nfeatures: 1000))
        let stats = GPUOps.texturePoolStats

        XCTAssertGreaterThan(stats.hits, 0, "no texture was ever recycled")
        XCTAssertGreaterThan(stats.misses, missesAfterFirst - 1)
        XCTAssertEqual(first.keypointCount, again.keypointCount)
        let (matched, onlyFirst, onlyAgain, maxDelta) = matchPositions(
          first.keypointPositions(), again.keypointPositions(), tolerance: 0.001)
        XCTAssertEqual(matched, first.keypointCount, "\(onlyFirst) / \(onlyAgain) keypoints differ on recycled textures")
        XCTAssertEqual(maxDelta, 0, accuracy: 1e-6)

        GPUOps.trimTexturePool()
        XCTAssertEqual(GPUOps.texturePoolStats.heldBytes, 0)
    }

    /// The GPU port against real cv::SIFT on a realistic sky — the comparison the
    /// sky detector's correctness actually rests on. The old MPS pyramid fails this
    /// by a wide margin: it widened every blur by a one-pixel box, which moved the
    /// stars' scale-space extrema and lost keypoints outright.
    func testGPUPortAgreesWithRealSIFTOnARealisticNightSky() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")

        let img = makeNightSky(width: 640, height: 480, stars: 700)

        let real = try XCTUnwrap(ImageAligner.debugSiftOpenCV(img, mask: nil, nfeatures: 2000))
        let gpu = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 2000))
        assertSameKeypoints(gpu, as: real, what: "the GPU port")
    }

    /// The DoG subtraction and the extremum scan run in parallel bands, concatenated in band order.
    /// That must reproduce the serial order, so repeated runs give byte-identical keypoints and
    /// descriptors (this was also compared against the serial version before it was removed).
    func testParallelExtremumScanIsDeterministic() throws {
        let img = makeNightSky(width: 800, height: 600, stars: 1200, seed: 5)
        let dir = NSTemporaryDirectory() + "sift-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var files: [Data] = []
        for run in 0..<3 {
            let r = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 4000))
            XCTAssertGreaterThan(r.keypointCount, 300)
            let path = "\(dir)/run\(run).yml"
            XCTAssertTrue(r.write(toFilename: path))
            files.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        XCTAssertEqual(files[0], files[1])
        XCTAssertEqual(files[1], files[2])
    }

    // MARK: - realistic sky

    /// A night sky the way `ia_find_features` hands it to the sky detector: point
    /// sources with a Gaussian profile a pixel or two wide, most of them faint, on
    /// a smooth gradient (the stretched glow of a moonlit or light-polluted sky)
    /// with sensor noise, quantised to 8 bits.
    private func makeNightSky(width: Int, height: Int, stars: Int, seed: UInt64 = 7) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var sky = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                sky[y * width + x] = 40 + 120 * Double(y) / Double(height) + 15 * Double(x) / Double(width)
            }
        }
        for _ in 0..<stars {
            let cx = rng.nextUnit() * Double(width)
            let cy = rng.nextUnit() * Double(height)
            let sigma = 0.7 + 0.8 * rng.nextUnit()
            // brightness falls off steeply, as star counts do: mostly faint, a few bright
            let peak = 6 + 200 * pow(rng.nextUnit(), 4)
            let reach = Int((4 * sigma).rounded(.up))
            for y in max(0, Int(cy) - reach)...min(height - 1, Int(cy) + reach) {
                for x in max(0, Int(cx) - reach)...min(width - 1, Int(cx) + reach) {
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    sky[y * width + x] += peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                }
            }
        }

        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for i in 0..<(width * height) {
            // Box-Muller, sigma 2
            let noise = 2 * (-2 * log(max(rng.nextUnit(), 1e-12))).squareRoot()
              * cos(2 * Double.pi * rng.nextUnit())
            data[i] = UInt8(clamping: Int((sky[i] + noise).rounded()))
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// `found` has to be the same keypoint set as `real`: the same count to within
    /// 2%, and 98% of `real`'s keypoints with one of `found`'s within half a pixel.
    private func assertSameKeypoints(_ found: OCVFeatureSet, as real: OCVFeatureSet,
                                     what: String) {
        XCTAssertGreaterThan(real.keypointCount, 300, "the sky has to yield enough keypoints to compare")
        XCTAssertEqual(Double(found.keypointCount), Double(real.keypointCount),
                       accuracy: Double(real.keypointCount) * 0.02,
                       "\(what) found \(found.keypointCount) keypoints where cv::SIFT found "
                       + "\(real.keypointCount)")
        let (matched, onlyReal, onlyFound, _) = matchPositions(
          real.keypointPositions(), found.keypointPositions(), tolerance: 0.5)
        XCTAssertGreaterThanOrEqual(matched, Int(Double(real.keypointCount) * 0.98),
                                    "only \(matched) of \(real.keypointCount) cv::SIFT keypoints had "
                                    + "a match from \(what) (unmatched: \(onlyReal) cv::SIFT-only, "
                                    + "\(onlyFound) \(what)-only)")
    }
}

/// A small, fast, deterministic PRNG — good enough for placing synthetic stars
/// reproducibly, nothing more.
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
    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }
}
