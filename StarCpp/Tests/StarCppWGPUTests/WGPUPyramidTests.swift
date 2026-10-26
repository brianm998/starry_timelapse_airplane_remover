import XCTest
import StarCpp
@testable import StarCppBridge

// Counts how often the wgpu pyramid handler answered yes. A handler that says no makes the detectors fall
// back to real OpenCV silently, so a test that only compares keypoints would pass without the wgpu pyramid
// ever having run; these counters are what rule that out. (A C function pointer cannot capture, hence globals.)
nonisolated(unsafe) private var siftPyramidsBuilt = 0
nonisolated(unsafe) private var siftPyramidsRefused = 0
nonisolated(unsafe) private var akazePyramidsBuilt = 0
nonisolated(unsafe) private var akazePyramidsRefused = 0

/// The wgpu backend's SIFT and AKAZE scale-space pyramids (WGPUBackend.cpp, kernels in WGPUImageShaders.h),
/// held to the same bars as the Metal pyramids (SIFTDetectorTests, AKAZEDetectorTests): they are not
/// compared pixel for pixel, they must yield the keypoints the CPU detectors yield.
///
/// Run with STAR_WGPU=1; skipped without wgpu-native, without the opt-in, or without an adapter.
final class WGPUPyramidTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(wgpu_ops_compiled_in(), "built without wgpu-native (wgpu/fetch.sh)")
        try XCTSkipUnless(wgpu_ops_opted_in(), "the wgpu backend is opt-in: run with STAR_WGPU=1")
        try XCTSkipUnless(wgpu_ops_available(), "no usable wgpu adapter on this machine")
        siftPyramidsBuilt = 0; siftPyramidsRefused = 0
        akazePyramidsBuilt = 0; akazePyramidsRefused = 0
        // Whatever backend an earlier test registered, these tests run the wgpu pyramids.
        gpu_ops_set_sift_pyramid_handler { base, doubleImageSize, sigma, nOctaves, nOctaveLayers, out in
            let ok = wgpu_ops_sift_pyramid(base, doubleImageSize, sigma, nOctaves, nOctaveLayers, out)
            if ok { siftPyramidsBuilt += 1 } else { siftPyramidsRefused += 1 }
            return ok
        }
        gpu_ops_set_akaze_pyramid_handler { img, soffset, levels, levelCount, stepCounts, tsteps, tstepsCount,
                                            kcontrastBase, outLt, outLsmooth in
            let ok = wgpu_ops_akaze_pyramid(img, soffset, levels, levelCount, stepCounts, tsteps, tstepsCount,
                                            kcontrastBase, outLt, outLsmooth)
            if ok { akazePyramidsBuilt += 1 } else { akazePyramidsRefused += 1 }
            return ok
        }
    }

    // MARK: - SIFT

    /// Hard-edged discs of many sizes: the pattern cv::SIFT reliably finds features on (see
    /// SIFTDetectorTests.makeStarField for why synthetic frames usually yield none).
    private func makeStarField(width: Int, height: Int, count: Int, seed: UInt64 = 1) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 4, count: width * height)
        for _ in 0..<count {
            let cx = Int(rng.nextUInt32() % UInt32(width)), cy = Int(rng.nextUInt32() % UInt32(height))
            let radius = 4 + Int(rng.nextUInt32() % 14)
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < width, y >= 0, y < height { pixels[y * width + x] = 250 }
                }
            }
        }
        return gray8(width: width, height: height, pixels)
    }

    /// A night sky the way ia_find_features hands it to the sky detector: Gaussian point sources a pixel or
    /// two wide, mostly faint, on a smooth gradient with sensor noise, quantised to 8 bits.
    private func makeNightSky(width: Int, height: Int, stars: Int, seed: UInt64 = 7) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var sky = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { sky[y * width + x] = 40 + 120 * Double(y) / Double(height) + 15 * Double(x) / Double(width) }
        }
        for _ in 0..<stars {
            let cx = rng.nextUnit() * Double(width), cy = rng.nextUnit() * Double(height)
            let sigma = 0.7 + 0.8 * rng.nextUnit()
            let peak = 6 + 200 * pow(rng.nextUnit(), 4)
            let reach = Int((4 * sigma).rounded(.up))
            for y in max(0, Int(cy) - reach)...min(height - 1, Int(cy) + reach) {
                for x in max(0, Int(cx) - reach)...min(width - 1, Int(cx) + reach) {
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    sky[y * width + x] += peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                }
            }
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let noise = 2 * (-2 * log(max(rng.nextUnit(), 1e-12))).squareRoot() * cos(2 * Double.pi * rng.nextUnit())
            pixels[i] = UInt8(clamping: Int((sky[i] + noise).rounded()))
        }
        return gray8(width: width, height: height, pixels)
    }

    private func gray8(width: Int, height: Int, _ pixels: [UInt8]) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        data.update(from: pixels, count: width * height)
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    /// Greedy nearest-neighbour matching of two position sets, each point used once.
    private func matchPositions(_ a: [(x: Double, y: Double)], _ b: [(x: Double, y: Double)],
                                tolerance: Double) -> (matched: Int, onlyA: Int, onlyB: Int, maxDelta: Double) {
        var used = Set<Int>(), matched = 0, maxDelta = 0.0
        for pa in a {
            var best = -1, bestDist = Double.greatestFiniteMagnitude
            for (j, pb) in b.enumerated() where !used.contains(j) {
                let d = (pa.x - pb.x) * (pa.x - pb.x) + (pa.y - pb.y) * (pa.y - pb.y)
                if d < bestDist { bestDist = d; best = j }
            }
            if best >= 0, bestDist.squareRoot() <= tolerance {
                used.insert(best); matched += 1; maxDelta = max(maxDelta, bestDist.squareRoot())
            }
        }
        return (matched, a.count - matched, b.count - matched, maxDelta)
    }

    /// The wgpu pyramid under the very same detector the CPU reference runs: only the pyramid differs, so
    /// the keypoints have to agree. The Metal pyramid is held to the same bar (98% within 1.5 px).
    func testSiftPyramidAgreesWithTheCPUPyramid() throws {
        let img = makeStarField(width: 512, height: 384, count: 40)
        let reference = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 500))
        let gpu = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 500))
        XCTAssertGreaterThan(siftPyramidsBuilt, 0, "the wgpu pyramid never ran (refused \(siftPyramidsRefused) times)")
        XCTAssertGreaterThan(gpu.keypointCount, 0, "the wgpu pyramid path found no keypoints at all")
        let (matched, onlyRef, onlyGPU, maxDelta) = matchPositions(
          reference.keypointPositions(), gpu.keypointPositions(), tolerance: 1.5)
        print("wgpu SIFT pyramid vs CPU pyramid (star field): \(reference.keypointCount) reference, "
              + "\(gpu.keypointCount) wgpu, \(matched) matched, max delta \(maxDelta)")
        XCTAssertGreaterThanOrEqual(matched, Int(Double(reference.keypointCount) * 0.98),
                                    "only \(matched) of \(reference.keypointCount) reference keypoints matched "
                                    + "(\(onlyRef) reference-only, \(onlyGPU) wgpu-only)")
        XCTAssertLessThanOrEqual(maxDelta, 0.5)
    }

    /// On the realistic sky, the real cv::SIFT is the bar: the same keypoint count to within 2%, and 98% of
    /// its keypoints matched within half a pixel.
    func testSiftPyramidAgreesWithRealSIFTOnANightSky() throws {
        let img = makeNightSky(width: 640, height: 480, stars: 700)
        let real = try XCTUnwrap(ImageAligner.debugSiftOpenCV(img, mask: nil, nfeatures: 2000))
        let gpu = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 2000))
        XCTAssertGreaterThan(siftPyramidsBuilt, 0, "the wgpu pyramid never ran (refused \(siftPyramidsRefused) times)")
        XCTAssertGreaterThan(real.keypointCount, 300, "the sky has to yield enough keypoints to compare")
        let (matched, onlyReal, onlyGPU, maxDelta) = matchPositions(
          real.keypointPositions(), gpu.keypointPositions(), tolerance: 0.5)
        print("wgpu SIFT pyramid vs cv::SIFT (night sky): \(real.keypointCount) cv::SIFT, \(gpu.keypointCount) wgpu, "
              + "\(matched) matched within 0.5 px, max delta \(maxDelta)")
        XCTAssertEqual(Double(gpu.keypointCount), Double(real.keypointCount),
                       accuracy: Double(real.keypointCount) * 0.02)
        XCTAssertGreaterThanOrEqual(matched, Int(Double(real.keypointCount) * 0.98),
                                    "only \(matched) of \(real.keypointCount) cv::SIFT keypoints matched "
                                    + "(\(onlyReal) cv::SIFT-only, \(onlyGPU) wgpu-only)")
    }

    /// Pyramid buffers are pooled between builds, so a reused one carries the previous build's pixels. A
    /// second build of the same image, after one of a different image of the same size, must find exactly
    /// the same keypoints: nothing may read a buffer before writing it.
    func testRecycledPyramidBuffersGiveTheSameKeypoints() throws {
        let a = makeNightSky(width: 512, height: 384, stars: 400, seed: 11)
        let b = makeNightSky(width: 512, height: 384, stars: 400, seed: 23)
        let first = try XCTUnwrap(ImageAligner.debugSiftGPU(a, mask: nil, nfeatures: 1000))
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(b, mask: nil, nfeatures: 1000))
        let again = try XCTUnwrap(ImageAligner.debugSiftGPU(a, mask: nil, nfeatures: 1000))
        XCTAssertEqual(siftPyramidsBuilt, 3, "all three builds should have run on wgpu (refused \(siftPyramidsRefused))")
        XCTAssertEqual(first.keypointCount, again.keypointCount)
        let (matched, _, _, maxDelta) = matchPositions(first.keypointPositions(), again.keypointPositions(),
                                                       tolerance: 1e-6)
        XCTAssertEqual(matched, first.keypointCount, "a rebuilt pyramid moved keypoints (max delta \(maxDelta))")
    }

    /// A small frame builds; zero octaves or layers, or a pixel type that is not float, are refused (the
    /// CPU does those).
    func testSiftPyramidBuildsSmallFramesAndRefusesWhatItCannotDo() throws {
        let width = 256, height = 256
        let data = UnsafeMutablePointer<Float>.allocate(capacity: width * height)
        data.initialize(repeating: 0.5, count: width * height)
        let base = MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 32, componentsPerPixel: 1),
                              bytesPerRow: width * 4, data: UnsafeMutableRawPointer(data), takeOwnership: true)
        let count = 4 * 6
        var out = [MatWrapperRef?](repeating: nil, count: count)
        XCTAssertTrue(wgpu_ops_sift_pyramid(base.ref, true, 1.6, 4, 3, &out))
        for m in out { if let m { mat_wrapper_release(m) } }
        // zero octaves / layers, or the wrong pixel type, are refused outright
        var none = [MatWrapperRef?](repeating: nil, count: 1)
        XCTAssertFalse(wgpu_ops_sift_pyramid(base.ref, true, 1.6, 0, 3, &none))
        XCTAssertFalse(wgpu_ops_sift_pyramid(base.ref, true, 1.6, 4, 0, &none))
        let eight = gray8(width: 64, height: 64, [UInt8](repeating: 9, count: 64 * 64))
        XCTAssertFalse(wgpu_ops_sift_pyramid(eight.ref, true, 1.6, 4, 3, &none))
    }

    // MARK: - AKAZE

    /// The threshold this codebase uses in production (ImageAligner.cpp's earthDetectorThreshold).
    private let productionThreshold: Float = 1e-4

    /// Sharp-edged discs of many sizes: a Hessian-determinant detector finds nothing on a smooth image.
    private func makeTexturedField(width: Int, height: Int, count: Int, seed: UInt64 = 1) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var pixels = [UInt8](repeating: 40, count: width * height)
        for _ in 0..<count {
            let cx = Int(rng.nextUInt32() % UInt32(width)), cy = Int(rng.nextUInt32() % UInt32(height))
            let radius = 5 + Int(rng.nextUInt32() % 20)
            let bright = UInt8(180 + rng.nextUInt32() % 76)
            for dy in -radius...radius {
                for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                    let x = cx + dx, y = cy + dy
                    if x >= 0, x < width, y >= 0, y < height { pixels[y * width + x] = bright }
                }
            }
        }
        return gray8(width: width, height: height, pixels)
    }

    /// Ground-like texture: value noise summed over cell sizes from 64 px down to 2 px, each weaker than the
    /// last, plus pixel noise: fine, continuous structure at every scale, where a pyramid error shifts which
    /// responses win rather than leaving well-separated blobs ranked as before. Odd sizes on purpose: an odd
    /// dimension makes AKAZE's octave step 2.0006 rather than 2, which a 2x2 average cannot follow.
    private func makeGround(width: Int, height: Int, seed: UInt64 = 3) -> MatWrapper {
        var rng = SplitMix64(seed: seed)
        var field = [Double](repeating: 0, count: width * height)
        var amplitude = 1.0
        for cell in [64, 32, 16, 8, 4, 2] {
            let gw = width / cell + 2, gh = height / cell + 2
            let grid = (0..<(gw * gh)).map { _ in Double(rng.nextUInt32()) / Double(UInt32.max) }
            for y in 0..<height {
                let fy = Double(y) / Double(cell)
                let y0 = Int(fy), ty = fy - Double(y0)
                for x in 0..<width {
                    let fx = Double(x) / Double(cell)
                    let x0 = Int(fx), tx = fx - Double(x0)
                    let top = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x0 + 1] * tx
                    let bottom = grid[(y0 + 1) * gw + x0] * (1 - tx) + grid[(y0 + 1) * gw + x0 + 1] * tx
                    field[y * width + x] += amplitude * (top * (1 - ty) + bottom * ty)
                }
            }
            amplitude *= 0.6
        }
        let lo = field.min() ?? 0, hi = field.max() ?? 1
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let v = (field[i] - lo) / (hi - lo) * 235 + 10 + Double(rng.nextUInt32() % 7) - 3
            pixels[i] = UInt8(clamping: Int(v.rounded()))
        }
        return gray8(width: width, height: height, pixels)
    }

    /// The wgpu pyramid under the very same detector the CPU reference runs: only the pyramid differs.
    func testAkazePyramidAgreesWithTheCPUPyramid() throws {
        let img = makeTexturedField(width: 512, height: 384, count: 60)
        let reference = try XCTUnwrap(ImageAligner.debugAkazeReference(img, mask: nil, maxKeypoints: 500,
                                                                       threshold: productionThreshold))
        let gpu = try XCTUnwrap(ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 500,
                                                           threshold: productionThreshold))
        XCTAssertGreaterThan(akazePyramidsBuilt, 0, "the wgpu pyramid never ran (refused \(akazePyramidsRefused) times)")
        XCTAssertGreaterThan(gpu.keypointCount, 0, "the wgpu pyramid path found no keypoints at all")
        let (matched, onlyRef, onlyGPU, maxDelta) = matchPositions(
          reference.keypointPositions(), gpu.keypointPositions(), tolerance: 0.5)
        print("wgpu AKAZE pyramid vs CPU pyramid (textured field): \(reference.keypointCount) reference, "
              + "\(gpu.keypointCount) wgpu, \(matched) matched, max delta \(maxDelta)")
        // 96%, not the 98% the SIFT comparison uses: measured 492 of 501 (98.2%), a margin one platform's float
        // rounding could eat. The misses sit at the 500-keypoint cap, where a response that differs in the
        // last bits swaps which keypoints make the cut; the comparison with real cv::AKAZE below is the
        // sharp one (all 1909 of 1909, to 0.0008 px).
        XCTAssertGreaterThanOrEqual(matched, Int(Double(reference.keypointCount) * 0.96),
                                    "only \(matched) of \(reference.keypointCount) reference keypoints matched "
                                    + "(\(onlyRef) reference-only, \(onlyGPU) wgpu-only)")
        XCTAssertLessThanOrEqual(maxDelta, 0.5)
    }

    /// On ground-like texture the real cv::AKAZE is the bar: the same keypoint count to within 2% and 98% of
    /// its keypoints matched within half a pixel.
    func testAkazePyramidAgreesWithRealAKAZEOnARealisticGround() throws {
        let img = makeGround(width: 641, height: 481)
        let real = try XCTUnwrap(ImageAligner.debugAkazeOpenCV(img, mask: nil, maxKeypoints: 2000,
                                                               threshold: productionThreshold))
        let gpu = try XCTUnwrap(ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 2000,
                                                           threshold: productionThreshold))
        XCTAssertGreaterThan(akazePyramidsBuilt, 0, "the wgpu pyramid never ran (refused \(akazePyramidsRefused) times)")
        XCTAssertGreaterThan(real.keypointCount, 300, "the ground has to yield enough keypoints to compare")
        let (matched, onlyReal, onlyGPU, maxDelta) = matchPositions(
          real.keypointPositions(), gpu.keypointPositions(), tolerance: 0.5)
        print("wgpu AKAZE pyramid vs cv::AKAZE (ground): \(real.keypointCount) cv::AKAZE, \(gpu.keypointCount) wgpu, "
              + "\(matched) matched within 0.5 px, max delta \(maxDelta)")
        XCTAssertEqual(Double(gpu.keypointCount), Double(real.keypointCount),
                       accuracy: Double(real.keypointCount) * 0.02)
        XCTAssertGreaterThanOrEqual(matched, Int(Double(real.keypointCount) * 0.98),
                                    "only \(matched) of \(real.keypointCount) cv::AKAZE keypoints matched "
                                    + "(\(onlyReal) cv::AKAZE-only, \(onlyGPU) wgpu-only)")
    }

    /// Buffers are pooled between builds; a rebuild of the same image after one of another of the same size
    /// must find exactly the same keypoints.
    func testRecycledAkazeBuffersGiveTheSameKeypoints() throws {
        let a = makeGround(width: 513, height: 385, seed: 5)
        let b = makeGround(width: 513, height: 385, seed: 9)
        let first = try XCTUnwrap(ImageAligner.debugAkazeGPU(a, mask: nil, maxKeypoints: 1000, threshold: productionThreshold))
        _ = try XCTUnwrap(ImageAligner.debugAkazeGPU(b, mask: nil, maxKeypoints: 1000, threshold: productionThreshold))
        let again = try XCTUnwrap(ImageAligner.debugAkazeGPU(a, mask: nil, maxKeypoints: 1000, threshold: productionThreshold))
        XCTAssertEqual(akazePyramidsBuilt, 3, "all three builds should have run on wgpu (refused \(akazePyramidsRefused))")
        XCTAssertEqual(first.keypointCount, again.keypointCount)
        let (matched, _, _, maxDelta) = matchPositions(first.keypointPositions(), again.keypointPositions(),
                                                       tolerance: 1e-6)
        XCTAssertEqual(matched, first.keypointCount, "a rebuilt pyramid moved keypoints (max delta \(maxDelta))")
    }
}

/// A small, fast, deterministic PRNG: enough for placing synthetic stars reproducibly.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUInt32() -> UInt32 { UInt32(truncatingIfNeeded: nextUInt64()) }
    mutating func nextUnit() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }
}
