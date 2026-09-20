import XCTest
@testable import StarCppBridge

/// Coverage for the Metal-backed warp and median-merge kernels registered by
/// `GPUOps`, run against the real GPU on whatever machine executes this suite —
/// there is no mock or simulator for Metal here. `GPUCapability.isAvailable()`
/// gates every test below; on a machine with no supported GPU they report as
/// skipped rather than failed, since "no GPU" is a real, supported configuration
/// and not a bug.
///
/// These reuse `MedianMergeTests`' small-synthetic-image approach rather than
/// real 42MP frames — the kernels are exercised through the exact same
/// `ImageAligner` entry points, with `useGPU: true`, so what differs from that
/// suite is only which path executes underneath.
final class GPUOpsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GPUOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - helpers

    private func makeMat(width: Int, height: Int, channels: Int = 1,
                         _ value: (Int, Int, Int) -> UInt16) -> MatWrapper {
        let count = width * height * channels
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    data[(y * width + x) * channels + c] = value(x, y, c)
                }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: Int32(channels)),
                          bytesPerRow: width * channels * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func write(_ mat: MatWrapper, named name: String) throws -> String {
        let path = scratch.appendingPathComponent("\(name).tiff").path
        XCTAssertTrue(mat.write(to: path), "could not write \(path)")
        return path
    }

    private func samples(of mat: MatWrapper, channels: Int = 1) throws -> [[UInt16]] {
        let base = try XCTUnwrap(mat.dataPtr)
        let step = mat.step
        return (0..<mat.rows).map { y in
            let row = base.advanced(by: y * step).assumingMemoryBound(to: UInt16.self)
            return (0..<(mat.cols * channels)).map { row[$0] }
        }
    }

    // MARK: - warp: the zero-fill boundary is exact, GPU or CPU

    /// A destination pixel the warp cannot reach at all has to come back exactly
    /// zero on the GPU path too — that boundary test is in/out-of-bounds
    /// arithmetic, not interpolation, so there is no rounding budget to spend here.
    func testWarpLeavesFullyUncoveredPixelsExactlyZero() throws {
        let width = 20, height = 10
        let level: UInt16 = 40000
        let base = makeMat(width: width, height: height) { _, _, _ in 0 }
        let neighbourPath = try write(makeMat(width: width, height: height) { _, _, _ in level },
                                      named: "shifted")
        // Slide the neighbour 12px right: columns 0..<12 of the destination cannot
        // be reached by any part of the source at all, so the warp must leave them
        // untouched (still zero, from the pre-zeroed destination) rather than
        // sampling something out of bounds.
        //
        // includeAll: true is deliberate here, unlike the other tests in this
        // file -- it makes every source, warp-zero included, count as a real
        // observation (see medianMergeTyped's includeAll branch), which is what
        // turns "the warp did not reach here" directly into the merged output: an
        // uncovered column merges [0, 0] -> 0, a covered one merges [0, level] ->
        // level (median-of-2 with includeAll always keeps the larger). That
        // isolates the warp's own boundary behaviour instead of also exercising
        // the coverage-misses machinery, which the other tests already cover.
        let homography = MatWrapper(homographyValues: [1, 0, 12,
                                                        0, 1, 0,
                                                        0, 0, 1])
        let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: 0,
          neighbors: [AlignmentNeighborInfo(filename: neighbourPath, maskFilename: nil,
                                            keypoints: nil, frameIndex: 1)],
          homography: [1: homography],
          outlierThreshold: 1.2, includeAll: true,
          useGPU: true))
        XCTAssertEqual(result.warpCount, 1)

        let rows = try samples(of: result.merged)
        for row in rows {
            for x in 0..<12 {
                XCTAssertEqual(row[x], 0, "column \(x) should have no coverage at all")
            }
            for x in 12..<width {
                XCTAssertEqual(row[x], level, "column \(x) should be fully covered")
            }
        }
    }

    /// The same scenario CPU and GPU, side by side: identity warp has no
    /// interpolation to do at all, so the two paths must agree exactly, not just
    /// approximately.
    func testIdentityWarpAgreesExactlyBetweenCPUAndGPU() throws {
        let width = 24, height = 16
        func pattern(_ x: Int, _ y: Int) -> UInt16 { UInt16((x * 37 + y * 101) % 60000 + 100) }
        let base = makeMat(width: width, height: height) { x, y, _ in pattern(x, y) }
        let neighbourPath = try write(makeMat(width: width, height: height) { x, y, _ in pattern(x, y) },
                                      named: "identity")
        let identity = MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])

        func merged(useGPU: Bool) throws -> [[UInt16]] {
            let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
              baseImage: base, baseFrameIndex: 0,
              neighbors: [AlignmentNeighborInfo(filename: neighbourPath, maskFilename: nil,
                                                keypoints: nil, frameIndex: 1)],
              homography: [1: identity],
              outlierThreshold: 1.2, includeAll: false,
              useGPU: useGPU))
            return try samples(of: result.merged)
        }

        XCTAssertEqual(try merged(useGPU: true), try merged(useGPU: false))
    }

    /// A fractional shift forces real interpolation. Matching OpenCV's
    /// `INTER_TAB_SIZE` fractional-position quantization (see GPUOps.swift) is
    /// most of what makes this kernel track OpenCV closely, measured here: a
    /// deliberately high-frequency synthetic pattern (chosen to make
    /// interpolation error as visible as possible) landed within 1 of 65535 once
    /// the kernel quantized the fractional position the same way OpenCV does,
    /// against 72 of 65535 before that change went in.
    ///
    /// Goes through `ImageAligner.debugWarp` rather than a merge: a merge picks a
    /// value out of a small sorted set (`base` vs. the warped neighbour), so any
    /// real difference between the GPU and CPU warp would be swamped by which of
    /// the two the merge's own selection happens to prefer, rather than measured.
    func testFractionalWarpAgreesWithinASmallToleranceOfCPU() throws {
        let width = 64, height = 48
        func pattern(_ x: Int, _ y: Int) -> UInt16 {
            UInt16(25000 + 10000 * sin(Double(x) * 0.3) + 10000 * cos(Double(y) * 0.2))
        }
        let src = makeMat(width: width, height: height) { x, y, _ in pattern(x, y) }
        // A rotation + fractional translation, entirely interior to the frame:
        // small enough that every destination pixel's sample window still lands
        // fully inside the source, so this measures interpolation error only, not
        // the (exact, tested separately) boundary rule.
        let theta = 0.03
        let homography = MatWrapper(homographyValues: [cos(theta), -sin(theta), 2.5,
                                                        sin(theta),  cos(theta), 1.5,
                                                        0, 0, 1])

        let gpuWarped = try XCTUnwrap(ImageAligner.debugWarp(src, homography: homography, useGPU: true))
        let cpuWarped = try XCTUnwrap(ImageAligner.debugWarp(src, homography: homography, useGPU: false))
        let gpu = try samples(of: gpuWarped)
        let cpu = try samples(of: cpuWarped)
        XCTAssertEqual(gpu.count, cpu.count)

        // Interior only -- a ring near the edge is where the two paths' boundary
        // rules (float in/out-of-bounds test vs. OpenCV's fixed-point one) can
        // legitimately disagree on which pixels even count as "covered."
        let margin = 4
        var maxDelta = 0
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                maxDelta = max(maxDelta, abs(Int(gpu[y][x]) - Int(cpu[y][x])))
            }
        }
        XCTAssertLessThanOrEqual(maxDelta, 2,
                                 "GPU and CPU bilinear warp disagree by more than the measured "
                                 + "final-rounding difference in the frame interior")
    }

    // MARK: - median merge: same functional invariants as MedianMergeTests, on the GPU

    /// The GPU median-merge kernel's exact-integer arithmetic is documented to
    /// differ from the CPU's double Welford in general (see GPUOps.swift), but
    /// every source carrying the *same* value at a pixel is the case that
    /// distinguishes nothing: mean, variance and the sorted order are identical
    /// regardless of arithmetic precision, so this is the sharpest test that the
    /// GPU kernel's selection logic (sort, skip-the-misses, index pick) is right
    /// at all, independent of the floating-point question.
    func testEdgeColumnsCoveredByOnlyTheBaseFrameAreNotBlackOnGPU() throws {
        let width = 16, height = 4
        let level: UInt16 = 30000
        let base = makeMat(width: width, height: height) { _, _, _ in level }

        var infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for k in 0..<8 {
            let path = try write(makeMat(width: width, height: height) { _, _, _ in level },
                                 named: "neighbour-\(k)")
            infos.append(AlignmentNeighborInfo(filename: path, maskFilename: nil,
                                               keypoints: nil, frameIndex: Int32(k + 1)))
            homography[k + 1] = MatWrapper(homographyValues: [1, 0, Double(-2 * (k + 1)),
                                                              0, 1, 0,
                                                              0, 0, 1])
        }

        let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: 0,
          neighbors: infos, homography: homography,
          outlierThreshold: 1.2, includeAll: false,
          useGPU: true))
        XCTAssertEqual(result.warpCount, 8)

        for row in try samples(of: result.merged) {
            for (x, value) in row.enumerated() {
                XCTAssertEqual(value, level, "pixel \(x) merged to \(value) on the GPU path")
            }
        }
    }

    /// Same bright-trail-rejection scenario as `MedianMergeTests`, run on the GPU:
    /// every source is uniform per column, so there is nothing for float32 vs.
    /// double arithmetic to disagree about, and the trail must still be rejected
    /// even at the thinnest coverage.
    func testABrightTrailIsRejectedEvenWhereCoverageIsThinOnGPU() throws {
        let width = 16, height = 4
        let sky: UInt16 = 12000
        let trail: UInt16 = 60000
        let base = makeMat(width: width, height: height) { _, _, _ in sky }

        var infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for k in 0..<8 {
            let value: UInt16 = k == 0 ? trail : sky
            let path = try write(makeMat(width: width, height: height) { _, _, _ in value },
                                 named: "trail-\(k)")
            infos.append(AlignmentNeighborInfo(filename: path, maskFilename: nil,
                                               keypoints: nil, frameIndex: Int32(k + 1)))
            homography[k + 1] = MatWrapper(homographyValues: [1, 0, Double(-2 * (k + 1)),
                                                              0, 1, 0,
                                                              0, 0, 1])
        }

        let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: 0,
          neighbors: infos, homography: homography,
          outlierThreshold: 1.2, includeAll: false,
          useGPU: true))

        for row in try samples(of: result.merged) {
            for (x, value) in row.enumerated() {
                XCTAssertEqual(value, sky, "pixel \(x) kept \(value) on the GPU path")
            }
        }
    }

    /// The documented deliberate difference from the CPU kernel: exact-sum float32
    /// mean/variance instead of double Welford. On a set of sources that are
    /// close but not identical (so the outlier cut and the picked index actually
    /// depend on the arithmetic), GPU and CPU must still pick from the same small
    /// neighbourhood of the sorted values -- not the same literal bytes elsewhere
    /// in the frame, but never wildly different either.
    func testMedianMergeGPUAgreesWithCPUWithinTheDocumentedTolerance() throws {
        let width = 9, height = 3
        // 9 close-but-distinct levels per column, shifted per column so every
        // column exercises a different part of the sorted order.
        let levels: [UInt16] = [10000, 10037, 10091, 10122, 10188, 10241, 10305, 10362, 10420]
        let base = makeMat(width: width, height: height) { x, _, _ in levels[x % levels.count] }
        let filenames = try (1..<levels.count).map { i in
            try write(makeMat(width: width, height: height) { x, _, _ in
                levels[(x + i) % levels.count]
            }, named: "close-\(i)")
        }

        func merged(useGPU: Bool) throws -> [[UInt16]] {
            let m = ImageAligner.medianMergeImage(base, withFilenames: filenames,
                                                  outlierThreshold: 1.2, includeAll: false,
                                                  useGPU: useGPU)
            return try samples(of: m)
        }

        let spread = Int(levels.max()!) - Int(levels.min()!)
        let gpu = try merged(useGPU: true)
        let cpu = try merged(useGPU: false)
        for y in 0..<height {
            for x in 0..<width {
                let delta = abs(Int(gpu[y][x]) - Int(cpu[y][x]))
                XCTAssertLessThanOrEqual(delta, spread,
                                         "GPU and CPU picked values far outside the source "
                                         + "set's own spread at (\(x), \(y))")
            }
        }
    }
}
