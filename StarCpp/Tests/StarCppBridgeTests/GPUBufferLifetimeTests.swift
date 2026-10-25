import XCTest
import Darwin
@testable import StarCppBridge

/// GPU calls must not leave their buffers behind: not in an autorelease pool nobody drains, and
/// not in the resource pools while memory is short.
///
/// Reading a Metal buffer through `contents()` makes Swift retain and autorelease the buffer,
/// so it lives until an autorelease pool drains, and the worker threads star runs these on
/// seldom drain one. Each GPU warp used to leave its destination buffer alive that way, and
/// each pyramid build every readback buffer the pool did not keep: ~430MB a sky keypoint op
/// at 4240x2832 / 1.5, piling up op after op, until a 7GB CI runner's memory gate admitted one
/// keypoint op a minute. A test method drains no pool between iterations either, so a leak
/// shows here as footprint that grows with the iteration count.
final class GPUBufferLifetimeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
    }

    func testRepeatedWarpsDoNotAccumulateDestinationBuffers() throws {
        try XCTSkipUnless(gpu_ops_warp_available(), "no GPU warp handler registered")
        let width = 3000, height = 2000
        let src = pattern(width: width, height: height, channels: 3)
        let homography = shift(dx: 3.5, dy: -2.25)
        let frameBytes = UInt64(width * height * 3)

        _ = try XCTUnwrap(ImageAligner.debugWarp(src, homography: homography, useGPU: true))
        let before = footprint()
        for _ in 0..<10 {
            _ = try XCTUnwrap(ImageAligner.debugWarp(src, homography: homography, useGPU: true))
        }
        let growth = footprintGrowth(since: before)
        XCTAssertLessThan(growth, 2 * frameBytes,
                          "10 warps grew the footprint by \(growth / 1_048_576)MB; "
                          + "each frame is \(frameBytes / 1_048_576)MB")
    }

    func testRepeatedPyramidBuildsDoNotAccumulateReadbackBuffers() throws {
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")
        let width = 1536, height = 1024
        let img = pattern(width: width, height: height, channels: 1)

        // The first build fills the texture and readback pools; later ones reuse them.
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 1000))
        let before = footprint()
        for _ in 0..<5 {
            _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 1000))
        }
        let growth = footprintGrowth(since: before)
        // A build's pyramid is ~128 bytes per input pixel (the first octave is upscaled 2x and
        // has six float levels), and each build used to leak about two thirds of it.
        let budget = UInt64(width * height) * 32
        XCTAssertLessThan(growth, budget,
                          "5 pyramid builds grew the footprint by \(growth / 1_048_576)MB")
    }

    /// While pooling is off (`MemoryMonitor` has work waiting for memory) the pools hold
    /// nothing: turning it off empties them, a build keeps none of its textures, and turning it
    /// back on lets the next build pool them again.
    func testPoolsKeepNothingWhilePoolingIsOff() throws {
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")
        defer { GPUOps.setPoolingAllowed(true) }
        let img = pattern(width: 512, height: 384, channels: 1)

        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 500))
        XCTAssertGreaterThan(GPUOps.texturePoolStats.heldBytes, 0)

        GPUOps.setPoolingAllowed(false)
        XCTAssertEqual(GPUOps.texturePoolStats.heldBytes, 0, "turning pooling off left textures pooled")
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 500))
        XCTAssertEqual(GPUOps.texturePoolStats.heldBytes, 0, "a build pooled its textures with pooling off")

        GPUOps.setPoolingAllowed(true)
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 500))
        XCTAssertGreaterThan(GPUOps.texturePoolStats.heldBytes, 0)
    }

    // MARK: - helpers

    /// An 8-bit image with structure SIFT can find: a gradient and a grid of bright spots.
    private func pattern(width: Int, height: Int, channels: Int) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * channels)
        for y in 0..<height {
            for x in 0..<width {
                let spot = (x % 37 == 5 && y % 29 == 7) ? 180 : 0
                let value = UInt8(clamping: 20 + (x + y) % 60 + spot)
                for c in 0..<channels { data[(y * width + x) * channels + c] = value }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: Int32(channels)),
                          bytesPerRow: width * channels, data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func shift(dx: Float, dy: Float) -> MatWrapper {
        let h = UnsafeMutablePointer<Float>.allocate(capacity: 9)
        for (i, v) in [Float(1), 0, dx, 0, 1, dy, 0, 0, 1].enumerated() { h[i] = v }
        return MatWrapper(width: 3, height: 3,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 32, componentsPerPixel: 1),
                          bytesPerRow: 3 * MemoryLayout<Float>.size, data: UnsafeMutableRawPointer(h),
                          takeOwnership: true)
    }

    /// How far the footprint has risen since `before`; zero if it fell, as it can when an
    /// earlier test's memory is given back meanwhile.
    private func footprintGrowth(since before: UInt64) -> UInt64 {
        let now = footprint()
        return now > before ? now - before : 0
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
