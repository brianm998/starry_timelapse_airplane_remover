import XCTest
import StarCpp
@testable import StarCppBridge

/// The wgpu-native backend (WGPUBackend.cpp, kernels in WGPUShaders.h), run on whatever adapter the
/// machine has: a real GPU through Vulkan / Direct3D 12 / Metal, or a software one (lavapipe, WARP)
/// when STAR_WGPU_ALLOW_CPU_ADAPTER=1 — which is how CI runs it, since a hosted runner has no GPU.
///
/// The functions are called directly (`wgpu_ops_warp`, `wgpu_ops_aligned_merge`) rather than through the
/// registered handlers, so the answer does not depend on which backend `GPUOps` registered. They are
/// held to the CPU path, which is the reference, to an exact double-precision model of the warp's
/// quantisation, and — on a Mac, where the Metal backend exists — to the Metal kernel, which these are a
/// port of. Not byte for byte: Metal carries the projection in float-float arithmetic, which a cross-vendor
/// shader compiler cannot be trusted to preserve, so this kernel uses a tile-origin formulation instead
/// (see WGPUShaders.h) that agrees with the exact model to about one pixel in a million and with Metal to
/// about a tenth of a percent of samples, which is closer to either than OpenCV's own CPU warp is.
///
/// Skipped, not failed, when the build has no wgpu-native (run wgpu/fetch.sh, then touch
/// StarCpp/Package.swift), STAR_WGPU is not set, or the machine has no usable adapter.
final class WGPUOpsTests: XCTestCase {

    override func setUpWithError() throws {
        // No setenv here (it is not in scope on Windows): wgpu.yml sets STAR_WGPU, and a local run does too.
        try XCTSkipUnless(wgpu_ops_compiled_in(), "built without wgpu-native (wgpu/fetch.sh)")
        try XCTSkipUnless(wgpu_ops_opted_in(), "the wgpu backend is opt-in: run with STAR_WGPU=1")
        try XCTSkipUnless(wgpu_ops_available(), "no usable wgpu adapter on this machine")
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    // MARK: - helpers

    /// A frame of `bits` (8 or 16) per component: sky-like gradient plus noise plus a few bright stars,
    /// so interpolation, rounding and the sigma clip all have something to do.
    private func frame(width: Int, height: Int, channels: Int, bits: Int, seed: Int) -> MatWrapper {
        let maxValue = bits == 8 ? 255 : 65535
        func value(_ x: Int, _ y: Int, _ c: Int) -> Int {
            var h = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663)
                           ^ (c &* 83_492_791) ^ (seed &* 2_654_435))
            h ^= h >> 13; h &*= 0x5bd1e995; h ^= h >> 15
            if (x * 31 + y * 17) % 997 == 0 { return maxValue * 3 / 4 }
            let scale = bits == 8 ? 1 : 256
            let sky = (24 + (x * 7 + y * 5) % 12 + c * 2) * scale
            return min(maxValue, sky + Int(h % UInt32(3 * scale)))
        }
        return make(width: width, height: height, channels: channels, bits: bits, value)
    }

    private func make(width: Int, height: Int, channels: Int, bits: Int,
                      _ value: (Int, Int, Int) -> Int) -> MatWrapper {
        let bytes = bits / 8
        let raw = UnsafeMutableRawPointer.allocate(byteCount: width * height * channels * bytes, alignment: 8)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let i = (y * width + x) * channels + c
                    if bits == 8 { raw.storeBytes(of: UInt8(value(x, y, c)), toByteOffset: i, as: UInt8.self) }
                    else { raw.storeBytes(of: UInt16(value(x, y, c)), toByteOffset: i * 2, as: UInt16.self) }
                }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: Int32(bits), componentsPerPixel: Int32(channels)),
                          bytesPerRow: width * channels * bytes, data: raw, takeOwnership: true)
    }

    private func zeros(like m: MatWrapper) -> MatWrapper {
        make(width: m.cols, height: m.rows, channels: m.channels, bits: m.bitsPerComponent) { _, _, _ in 0 }
    }

    /// Every component of `m`, row by row, as integers (no row padding).
    private func components(_ m: MatWrapper) throws -> [Int] {
        let base = try XCTUnwrap(m.dataPtr)
        let perRow = m.cols * m.channels
        var out = [Int](); out.reserveCapacity(perRow * m.rows)
        for y in 0..<m.rows {
            if m.bitsPerComponent == 8 {
                let row = base.advanced(by: y * m.step).assumingMemoryBound(to: UInt8.self)
                for i in 0..<perRow { out.append(Int(row[i])) }
            } else {
                let row = base.advanced(by: y * m.step).assumingMemoryBound(to: UInt16.self)
                for i in 0..<perRow { out.append(Int(row[i])) }
            }
        }
        return out
    }

    /// How many components differ, and the largest difference.
    private func compare(_ a: MatWrapper, _ b: MatWrapper) throws -> (differing: Int, total: Int, maxDelta: Int) {
        XCTAssertEqual(a.rows, b.rows); XCTAssertEqual(a.cols, b.cols); XCTAssertEqual(a.type, b.type)
        let pa = try components(a), pb = try components(b)
        var differing = 0, maxDelta = 0
        for i in 0..<pa.count where pa[i] != pb[i] {
            differing += 1
            maxDelta = max(maxDelta, abs(pa[i] - pb[i]))
        }
        return (differing, pa.count, maxDelta)
    }

    // MARK: - warp

    /// A rotation plus a perspective term, so the projection really is projective and the coordinates
    /// are large: the float-float arithmetic exists for exactly this, and it is the part a shader
    /// compiler is free to break (WGSL promises no ordering of float operations).
    private let perspective: [Double] = [1.0004, 0.011, 37.3,
                                         -0.009, 0.9997, -21.7,
                                         2.6e-7, -1.9e-7, 1]

    private func checkWarp(bits: Int, channels: Int, width: Int, height: Int,
                           maxMismatchFraction: Double) throws {
        let src = frame(width: width, height: height, channels: channels, bits: bits, seed: 1)
        let h = MatWrapper(homographyValues: perspective)
        let cpu = try XCTUnwrap(ImageAligner.debugWarp(src, homography: h, useGPU: false))
        let gpu = zeros(like: src)
        XCTAssertTrue(perspective.withUnsafeBufferPointer { wgpu_ops_warp(src.ref, $0.baseAddress, gpu.ref) })
        let r = try compare(gpu, cpu)
        let fraction = Double(r.differing) / Double(r.total)
        print("wgpu warp \(bits)-bit x\(channels) \(width)x\(height): \(r.differing) of \(r.total) differ "
              + "(\(fraction * 100)%), max delta \(r.maxDelta) — \(wgpu_ops_device_description().map { String(cString: $0) } ?? "?")")
        // Only the fraction is bounded: where the two land on different 1/32 steps they sample different
        // pixels, and on a noisy frame that is a large difference, not a rounding one.
        XCTAssertLessThan(fraction, maxMismatchFraction, "the wgpu and OpenCV warps differ too often")
    }

    /// The projection held to an exact double-precision reference of the quantisation (position rounded
    /// to 1/32 as a whole, ties to even, then bilinear), on a frame wide enough that a column is near
    /// 6000: a single float cannot hold that to better than 0.0005 px, which is why the kernel carries
    /// float-float. This isolates the arithmetic from OpenCV's own mismatches, and from Metal.
    func testWarpProjectionMatchesAnExactReferenceAtFullFrameWidth() throws {
        let width = 6000, height = 96
        let src = make(width: width, height: height, channels: 1, bits: 16) { x, _, _ in (x % 90) * 700 }
        let theta = 0.0004
        let hv = [cos(theta), -sin(theta), 3.37, sin(theta), cos(theta), 1.21, 0, 0, 1]
        let h = MatWrapper(homographyValues: hv)
        let gpu = zeros(like: src)
        XCTAssertTrue(hv.withUnsafeBufferPointer { wgpu_ops_warp(src.ref, $0.baseAddress, gpu.ref) })
        let out = try components(gpu)

        // inverse of a rotation + translation, in double
        let a = hv[0], b = hv[1], c = hv[2], d = hv[3], e = hv[4], f = hv[5]
        let det = a * e - b * d
        let inv = [e / det, -b / det, (b * f - c * e) / det, -d / det, a / det, (c * d - a * f) / det]
        var wrong = 0, total = 0
        let margin = 6
        for y in margin..<(height - margin) {
            for x in margin..<(width - margin) {
                let sx = inv[0] * Double(x) + inv[1] * Double(y) + inv[2]
                let xq = Int((sx * 32).rounded(.toNearestOrEven))
                let ix = xq >> 5, fx = Double(xq & 31) / 32
                func px(_ xx: Int) -> Double { Double(((xx % width) + width) % width % 90 * 700) }
                let expected = Int((px(ix) * (1 - fx) + px(ix + 1) * fx).rounded())
                total += 1
                if out[y * width + x] != expected { wrong += 1 }
            }
        }
        _ = h
        print("wgpu warp projection vs exact reference: \(wrong) of \(total) wrong")
        // Measured: 1 of 502,992 (the float-float kernel through wgpu's Metal compiler: 2,015, which is
        // what a plain float projection gives and why that design was dropped). OpenCV's own CPU warp is
        // off this reference at about 0.3% of pixels.
        XCTAssertLessThanOrEqual(wrong, total / 20_000,
                                 "the kernel sampled the wrong 1/32 step at \(wrong) of \(total) pixels")
    }

    func testWarp16BitRGBAgreesWithOpenCV() throws {
        try checkWarp(bits: 16, channels: 3, width: 1800, height: 1200, maxMismatchFraction: 0.01)
    }

    func testWarp8BitRGBAgreesWithOpenCV() throws {
        try checkWarp(bits: 8, channels: 3, width: 1801, height: 1199, maxMismatchFraction: 0.01)
    }

    func testWarp16BitGrayWithAnOddWidthAgreesWithOpenCV() throws {
        // an odd component count per row: output words straddle pixel boundaries
        try checkWarp(bits: 16, channels: 1, width: 1237, height: 771, maxMismatchFraction: 0.01)
    }

    /// The Metal warp is the same quantisation in MSL, exact where this is a hair off (see the class
    /// comment). Measured on noisy frames: 0.13% of 16-bit samples, 0.01% of 8-bit ones. OpenCV's own CPU
    /// warp is off Metal by more than that, so this is the sharper of the two comparisons.
    func testWarpMatchesTheMetalKernelClosely() throws {
        try XCTSkipUnless(GPUCapability.hasFullAcceleration(), "no Metal backend to compare with")
        GPUOps.registerIfAvailable()
        for (bits, channels) in [(16, 3), (8, 3), (16, 1)] {
            let src = frame(width: 1500, height: 900, channels: channels, bits: bits, seed: 2)
            let h = MatWrapper(homographyValues: perspective)
            let metal = try XCTUnwrap(ImageAligner.debugWarp(src, homography: h, useGPU: true))
            let gpu = zeros(like: src)
            XCTAssertTrue(perspective.withUnsafeBufferPointer { wgpu_ops_warp(src.ref, $0.baseAddress, gpu.ref) })
            let r = try compare(gpu, metal)
            XCTAssertLessThan(Double(r.differing) / Double(r.total), 0.003,
                              "\(bits)-bit x\(channels): \(r.differing) of \(r.total) samples differ from Metal")
        }
    }

    // MARK: - aligned merge

    private struct Fixture {
        let width: Int, height: Int, bits: Int
        let base: MatWrapper
        let neighbours: [MatWrapper]
        let infos: [AlignmentNeighborInfo]
        let homography: [Int: MatWrapper]
        let flat: [Double]   // the nine values per neighbour, in neighbour order
    }

    private func fixture(bits: Int, channels: Int = 3, width: Int = 640, height: Int = 480) -> Fixture {
        let base = frame(width: width, height: height, channels: channels, bits: bits, seed: 0)
        var neighbours: [MatWrapper] = [], infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:], flat: [Double] = []
        var pool: [String: MatWrapper] = [:]
        for (i, offset) in [-4, -3, -2, -1, 1, 2, 3, 4].enumerated() {
            let n = frame(width: width, height: height, channels: channels, bits: bits, seed: i + 1)
            let name = "memory://neighbour-\(i)"
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
        return Fixture(width: width, height: height, bits: bits, base: base, neighbours: neighbours,
                       infos: infos, homography: homography, flat: flat)
    }

    private func wgpuMerge(_ f: Fixture, includeAll: Bool) throws -> MatWrapper {
        XCTAssertTrue(wgpu_ops_aligned_merge_supported(), "this adapter cannot run the fused merge")
        let dst = zeros(like: f.base)
        var refs: [MatWrapperRef?] = f.neighbours.map { $0.ref }
        let ok = refs.withUnsafeMutableBufferPointer { buffer in
            f.flat.withUnsafeBufferPointer {
                wgpu_ops_aligned_merge(f.base.ref, buffer.baseAddress, Int32(f.neighbours.count),
                                       $0.baseAddress, 1.2, includeAll, dst.ref)
            }
        }
        XCTAssertTrue(ok)
        return dst
    }

    /// The merge built the long way round on the CPU: every neighbour warped on its own, its coverage
    /// read off a warp of a solid probe, then the standalone median merge.
    private func cpuMerge(_ f: Fixture, includeAll: Bool) throws -> MatWrapper {
        let pixels = f.width * f.height
        var solid = [UInt8](repeating: 255, count: pixels)
        let probe = solid.withUnsafeMutableBytes { raw in
            MatWrapper(width: f.width, height: f.height,
                       cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                       bytesPerRow: f.width, data: raw.baseAddress!, takeOwnership: true)
        }
        var warped: [MatWrapper] = []
        var misses = [UInt8](repeating: 0, count: pixels)
        for (i, neighbour) in f.neighbours.enumerated() {
            let h = try XCTUnwrap(f.homography[Int(f.infos[i].frameIndex)])
            warped.append(try XCTUnwrap(ImageAligner.debugWarp(neighbour, homography: h, useGPU: false)))
            let covered = try XCTUnwrap(ImageAligner.debugWarp(probe, homography: h, useGPU: false))
            let bytes = try XCTUnwrap(covered.dataPtr).assumingMemoryBound(to: UInt8.self)
            for y in 0..<f.height {
                for x in 0..<f.width where bytes[y * covered.step + x] == 0 { misses[y * f.width + x] += 1 }
            }
        }
        XCTAssertGreaterThan(misses.filter { $0 > 0 }.count, 0, "the fixture's warps should leave holes")
        let missesMat = misses.withUnsafeMutableBytes { raw in
            MatWrapper(width: f.width, height: f.height,
                       cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                       bytesPerRow: f.width, data: raw.baseAddress!, takeOwnership: true)
        }
        return try XCTUnwrap(ImageAligner.debugMedianMerge(
          [f.base] + warped, misses: includeAll ? nil : missesMat,
          outlierThreshold: 1.2, includeAll: includeAll, useGPU: false))
    }

    func testAlignedMergeAgreesWithTheCPUMerge() throws {
        for bits in [16, 8] {
            let f = fixture(bits: bits)
            for includeAll in [false, true] {
                let gpu = try wgpuMerge(f, includeAll: includeAll)
                let cpu = try cpuMerge(f, includeAll: includeAll)
                let r = try compare(gpu, cpu)
                let fraction = Double(r.differing) / Double(r.total)
                print("wgpu aligned merge \(bits)-bit includeAll=\(includeAll): \(r.differing) of \(r.total) "
                      + "differ (\(fraction * 100)%), max delta \(r.maxDelta)")
                // The CPU warp is off the exact 1/32 step at ~0.3% of pixels and the merge double-precision
                // Welford differs from float; both move a pixel's pick by at most the noise around it.
                XCTAssertLessThan(fraction, 0.03, "\(bits)-bit includeAll=\(includeAll)")
            }
        }
    }

    /// Measured: 50-88 of 921,600 samples (under 0.01%), a merge picks one value so a flipped warp step
    /// shows up far less than in the warp itself.
    func testAlignedMergeMatchesTheMetalKernelClosely() throws {
        try XCTSkipUnless(GPUCapability.hasFullAcceleration(), "no Metal backend to compare with")
        GPUOps.registerIfAvailable()
        for bits in [16, 8] {
            let f = fixture(bits: bits)
            for includeAll in [false, true] {
                let metal = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
                  baseImage: f.base, baseFrameIndex: 0, neighbors: f.infos, homography: f.homography,
                  outlierThreshold: 1.2, includeAll: includeAll, useGPU: true)).merged
                let gpu = try wgpuMerge(f, includeAll: includeAll)
                let r = try compare(gpu, metal)
                XCTAssertLessThan(Double(r.differing) / Double(r.total), 0.0005,
                                  "\(bits)-bit includeAll=\(includeAll): \(r.differing) of \(r.total) samples differ from Metal")
            }
        }
    }

    func testAlignedMergeRefusesWhatItCannotDo() throws {
        let f = fixture(bits: 16, width: 64, height: 48)
        var refs: [MatWrapperRef?] = f.neighbours.map { $0.ref }
        let dst = zeros(like: f.base)
        // no neighbours
        XCTAssertFalse(f.flat.withUnsafeBufferPointer {
            wgpu_ops_aligned_merge(f.base.ref, &refs, 0, $0.baseAddress, 1.2, false, dst.ref) })
        // a singular homography
        var singular = f.flat
        for k in 0..<9 { singular[k] = 0 }
        XCTAssertFalse(singular.withUnsafeBufferPointer {
            wgpu_ops_aligned_merge(f.base.ref, &refs, Int32(refs.count), $0.baseAddress, 1.2, false, dst.ref) })
        // a neighbour of a different size
        let odd = frame(width: 63, height: 48, channels: 3, bits: 16, seed: 9)
        var mismatched: [MatWrapperRef?] = [odd.ref]
        XCTAssertFalse(f.flat.withUnsafeBufferPointer {
            wgpu_ops_aligned_merge(f.base.ref, &mismatched, 1, $0.baseAddress, 1.2, false, dst.ref) })
    }
}
