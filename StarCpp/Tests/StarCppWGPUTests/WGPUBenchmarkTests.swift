import XCTest
import StarCpp
@testable import StarCppBridge

/// Timings, not tests: where a wgpu aligned merge or warp spends its time, beside the CPU path and (on a
/// Mac) the Metal backend. Skipped unless STAR_WGPU_BENCH is set, because a number from a software adapter
/// on a CI runner means nothing and a full-size frame takes a while.
///
///     STAR_WGPU=1 STAR_WGPU_BENCH=1 swift test --package-path StarCpp --filter WGPUBenchmarkTests
///
/// STAR_WGPU_BENCH_MP sets the frame size in megapixels (default 12). Frames are 16-bit RGB, the base and
/// eight neighbours, rotated and shifted like star-field neighbours. Read the "BENCH" lines.
final class WGPUBenchmarkTests: XCTestCase {

    private var megapixels: Double {
        Double(ProcessInfo.processInfo.environment["STAR_WGPU_BENCH_MP"] ?? "") ?? 12
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STAR_WGPU_BENCH"] != nil,
                          "benchmarks run only with STAR_WGPU_BENCH=1")
        try XCTSkipUnless(wgpu_ops_compiled_in(), "built without wgpu-native (wgpu/fetch.sh)")
        try XCTSkipUnless(wgpu_ops_opted_in(), "the wgpu backend is opt-in: run with STAR_WGPU=1")
        try XCTSkipUnless(wgpu_ops_available(), "no usable wgpu adapter on this machine")
    }

    /// A 16-bit RGB frame filled by a cheap deterministic generator (a closure per pixel is far too slow at
    /// this size).
    private func frame(width: Int, height: Int, seed: UInt32) -> MatWrapper {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        var state = seed &* 2_654_435_761 &+ 1
        for i in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let pixel = i / 3
            let sky = 6000 + (pixel % width) * 5 / 7 % 2500
            data[i] = UInt16(sky + Int(state >> 22))   // + 0...1023 of noise
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                          bytesPerRow: width * 6, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    private func seconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    private func report(_ label: String, wall: Double) {
        var t = [Double](repeating: 0, count: 6)
        guard wgpu_ops_last_timing(&t) else { return }
        let f = { (x: Double) in String(format: "%7.0f", x * 1000) }
        print("BENCH \(label): wall \(f(wall)) ms | prep \(f(t[0])) upload \(f(t[1])) record \(f(t[2])) "
              + "gpu \(f(t[3])) copyout \(f(t[4])) | in-call total \(f(t[5]))")
    }

    // MARK: - pyramids

    /// An 8-bit night-sky-like frame made cheaply (a gradient, a few thousand small gaussian stars, an LCG
    /// for noise): the detectors' CPU tails cost the same either way, it is the pyramids being compared.
    private func sky(width: Int, height: Int) -> MatWrapper {
        var field = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { field[y * width + x] = 40 + 120 * Float(y) / Float(height) + 15 * Float(x) / Float(width) }
        }
        var state: UInt64 = 12345
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        for _ in 0..<(width * height / 2500) {
            let cx = Int(next() * Float(width)), cy = Int(next() * Float(height))
            let peak = 8 + 200 * pow(next(), 4), sigma = 0.8 + 0.7 * next()
            let reach = Int((3 * sigma).rounded(.up))
            for y in max(0, cy - reach)...min(height - 1, cy + reach) {
                for x in max(0, cx - reach)...min(width - 1, cx + reach) {
                    let dx = Float(x - cx), dy = Float(y - cy)
                    field[y * width + x] += peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                }
            }
        }
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt8(clamping: Int(field[i] + (next() - 0.5) * 6)) }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    /// Whole-detector times (pyramid plus the CPU tail both share) for real OpenCV, Metal where there is
    /// one, and wgpu; and the wgpu SIFT pyramid by itself.
    func testPyramidTimings() throws {
        let width = Int((megapixels * 1e6 * 1.5).squareRoot()), height = Int((megapixels * 1e6 / 1.5).squareRoot())
        print("BENCH pyramid frame \(width)x\(height) = \(String(format: "%.1f", Double(width * height) / 1e6)) MP, 8-bit — "
              + "\(wgpu_ops_device_description().map { String(cString: $0) } ?? "?")")
        let img = sky(width: width, height: height)
        let ms = { (t: Double) in String(format: "%7.0f", t * 1000) }

        let sift = seconds { _ = ImageAligner.debugSiftOpenCV(img, mask: nil, nfeatures: 2000) }
        print("BENCH SIFT  real cv::SIFT:        wall \(ms(sift)) ms")
        let akaze = seconds { _ = ImageAligner.debugAkazeOpenCV(img, mask: nil, maxKeypoints: 2000, threshold: 1e-4) }
        print("BENCH AKAZE real cv::AKAZE:       wall \(ms(akaze)) ms")

        if GPUCapability.hasFullAcceleration() {
            GPUOps.registerIfAvailable()   // Metal's handlers; the wgpu ones replace them below
            for run in 1...2 {
                let t = seconds { _ = ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 2000) }
                print("BENCH SIFT  Metal pyramid run \(run): wall \(ms(t)) ms")
            }
            for run in 1...2 {
                let t = seconds { _ = ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 2000, threshold: 1e-4) }
                print("BENCH AKAZE Metal pyramid run \(run): wall \(ms(t)) ms")
            }
        }

        gpu_ops_set_sift_pyramid_handler { b, d, s, no, nl, out in wgpu_ops_sift_pyramid(b, d, s, no, nl, out) }
        gpu_ops_set_akaze_pyramid_handler { i, so, lv, lc, sc, ts, tc, kc, lt, ls in
            wgpu_ops_akaze_pyramid(i, so, lv, lc, sc, ts, tc, kc, lt, ls)
        }
        for run in 1...3 {
            let t = seconds { _ = ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 2000) }
            print("BENCH SIFT  wgpu pyramid run \(run):  wall \(ms(t)) ms")
        }
        for run in 1...3 {
            let t = seconds { _ = ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 2000, threshold: 1e-4) }
            print("BENCH AKAZE wgpu pyramid run \(run):  wall \(ms(t)) ms")
        }

        // the SIFT pyramid alone, on the float image the detector builds it from
        let count = width * height
        let floats = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let bytes = img.dataPtr!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { floats[i] = Float(bytes[i]) }
        let base = MatWrapper(width: width, height: height,
                              cvType: MatWrapper.cvType(forBitsPerComponent: 32, componentsPerPixel: 1),
                              bytesPerRow: width * 4, data: UnsafeMutableRawPointer(floats), takeOwnership: true)
        let octaves = Int(log2(Double(min(width, height) * 2)).rounded()) - 2
        for run in 1...3 {
            var out = [MatWrapperRef?](repeating: nil, count: octaves * 6)
            var ok = false
            let t = seconds { ok = wgpu_ops_sift_pyramid(base.ref, true, 1.6, Int32(octaves), 3, &out) }
            print("BENCH SIFT  wgpu pyramid only run \(run): wall \(ms(t)) ms, ok=\(ok), \(octaves) octaves")
            for m in out { if let m { mat_wrapper_release(m) } }
        }
    }

    func testAlignedMergeTimings() throws {
        let width = Int((megapixels * 1e6 * 1.5).squareRoot()), height = Int((megapixels * 1e6 / 1.5).squareRoot())
        print("BENCH frame \(width)x\(height) = \(String(format: "%.1f", Double(width * height) / 1e6)) MP, 16-bit RGB, "
              + "8 neighbours — \(wgpu_ops_device_description().map { String(cString: $0) } ?? "?")")
        let base = frame(width: width, height: height, seed: 1)
        let a = frame(width: width, height: height, seed: 2), b = frame(width: width, height: height, seed: 3)
        var neighbours: [MatWrapper] = [], infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:], flat: [Double] = []
        var pool: [String: MatWrapper] = [:]
        for (i, offset) in [-4, -3, -2, -1, 1, 2, 3, 4].enumerated() {
            let n = i % 2 == 0 ? a : b
            let name = "memory://bench-\(i)"
            pool[name] = n
            neighbours.append(n)
            infos.append(AlignmentNeighborInfo(filename: name, maskFilename: nil, keypoints: nil,
                                               frameIndex: Int32(offset)))
            let theta = 0.004 * Double(offset)
            let cx = Double(width) / 2, cy = Double(height) / 2
            let values = [cos(theta), -sin(theta), cx - cos(theta) * cx + sin(theta) * cy - 3.7 * Double(offset),
                          sin(theta), cos(theta), cy - sin(theta) * cx - cos(theta) * cy + 1.3 * Double(offset),
                          0, 0, 1]
            homography[offset] = MatWrapper(homographyValues: values)
            flat += values
        }
        ImageCache.setLoader { pool[$0] }

        // CPU, once: it is the thing to beat and it is slow
        let cpu = seconds {
            _ = ImageAligner.alignAndMedianMerge(baseImage: base, baseFrameIndex: 0, neighbors: infos,
                                                 homography: homography, outlierThreshold: 1.2,
                                                 includeAll: false, useGPU: false)
        }
        print("BENCH CPU aligned merge: wall \(String(format: "%7.0f", cpu * 1000)) ms")

        // Metal, where there is one (the registered backend on a Mac)
        if GPUCapability.hasFullAcceleration() {
            GPUOps.registerIfAvailable()
            for run in 1...3 {
                let t = seconds {
                    _ = ImageAligner.alignAndMedianMerge(baseImage: base, baseFrameIndex: 0, neighbors: infos,
                                                         homography: homography, outlierThreshold: 1.2,
                                                         includeAll: false, useGPU: true)
                }
                print("BENCH Metal aligned merge run \(run): wall \(String(format: "%7.0f", t * 1000)) ms")
            }
        }

        // wgpu: the first run pays for first-use costs, so three
        for run in 1...3 {
            let dst = MatWrapper(width: width, height: height,
                                 cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                                 bytesPerRow: width * 6,
                                 data: UnsafeMutableRawPointer.allocate(byteCount: width * height * 6, alignment: 8),
                                 takeOwnership: true)
            var refs: [MatWrapperRef?] = neighbours.map { $0.ref }
            let wall = seconds {
                XCTAssertTrue(refs.withUnsafeMutableBufferPointer { buffer in
                    flat.withUnsafeBufferPointer {
                        wgpu_ops_aligned_merge(base.ref, buffer.baseAddress, Int32(neighbours.count),
                                               $0.baseAddress, 1.2, false, dst.ref)
                    }
                })
            }
            report("wgpu aligned merge run \(run)", wall: wall)
        }

        // the standalone warp, for the same frame
        for run in 1...2 {
            let dst = MatWrapper(width: width, height: height,
                                 cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                                 bytesPerRow: width * 6,
                                 data: UnsafeMutableRawPointer.allocate(byteCount: width * height * 6, alignment: 8),
                                 takeOwnership: true)
            let wall = seconds {
                XCTAssertTrue(Array(flat[0..<9]).withUnsafeBufferPointer { wgpu_ops_warp(a.ref, $0.baseAddress, dst.ref) })
            }
            report("wgpu warp run \(run)", wall: wall)
        }
    }
}
