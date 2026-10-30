import XCTest
import Foundation
import StarCpp
@testable import StarCppBridge

/// The GPU pyramid builders can hand the CPU tail a Mat that IS the pooled readback buffer, instead
/// of a copy of it. Only where the bytes live changes, so everything here compares the two ways
/// of building the same pyramid (`STAR_READBACK=copy` / `GPUOps.setReadbackCopies`).
final class ZeroCopyReadbackTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no supported GPU on this machine")
        GPUOps.registerIfAvailable()
        try XCTSkipUnless(gpu_ops_sift_pyramid_available(), "no GPU SIFT pyramid handler registered")
    }

    override func tearDown() { GPUOps.setReadbackCopies(nil) }

    private func floatImage(width: Int, height: Int, seed: UInt32) -> MatWrapperRef {
        let ref = mat_wrapper_new(Int64(width), Int64(height), mat_wrapper_cv_type_for(32, 1))!
        let p = UnsafeMutablePointer<Float>(mutating: mat_wrapper_data_ptr(ref)!.assumingMemoryBound(to: Float.self))
        var state = seed
        for i in 0..<(width * height) {
            state = state &* 1664525 &+ 1013904223
            let x = i % width, y = i / width
            // Blobs on a noisy floor: enough structure for every level to differ from its neighbour.
            let blob = ((x / 23 + y / 17) % 5 == 0) ? 180.0 : 20.0
            p[i] = Float(blob) + Float(state >> 24) / 16.0
        }
        return ref
    }

    private func bytes(of ref: MatWrapperRef) -> Data {
        Data(bytes: mat_wrapper_data_ptr(ref)!, count: mat_wrapper_data_length(ref))
    }

    private func buildSift(_ base: MatWrapperRef, copies: Bool, nOctaves: Int = 4) throws -> [MatWrapperRef] {
        GPUOps.setReadbackCopies(copies)
        var out = [MatWrapperRef?](repeating: nil, count: nOctaves * 6)
        XCTAssertTrue(GPUOps.debugBuildSiftPyramid(base: base, doubleImageSize: true, sigma: 1.6,
                                                   nOctaves: nOctaves, nOctaveLayers: 3, outPyramid: &out))
        return try out.map { try XCTUnwrap($0) }
    }

    func testEveryLevelIsByteIdenticalToTheCopiedOne() throws {
        let base = floatImage(width: 400, height: 300, seed: 7)
        defer { mat_wrapper_release(base) }
        let copied = try buildSift(base, copies: true)
        let direct = try buildSift(base, copies: false)
        defer { (copied + direct).forEach { mat_wrapper_release($0) } }
        XCTAssertEqual(copied.count, direct.count)
        for (i, (a, b)) in zip(copied, direct).enumerated() {
            XCTAssertEqual(mat_wrapper_cols(a), mat_wrapper_cols(b), "level \(i)")
            XCTAssertEqual(mat_wrapper_rows(a), mat_wrapper_rows(b), "level \(i)")
            XCTAssertEqual(mat_wrapper_step(a), mat_wrapper_step(b), "level \(i)")
            XCTAssertTrue(bytes(of: a) == bytes(of: b), "level \(i) differs between copy and zero-copy")
        }
    }

    /// `MatWrapperImpl` shares an allocator-backed Mat instead of cloning it; if a later change to
    /// `canAdopt` made it clone, the readback would silently be a copy again (and the pool would
    /// get its buffer back early, which is harmless but would defeat R7).
    func testTheLevelsAreTheBuffersNotCopiesOfThem() throws {
        let base = floatImage(width: 256, height: 192, seed: 3)
        defer { mat_wrapper_release(base) }
        let copied = try buildSift(base, copies: true, nOctaves: 3)
        let direct = try buildSift(base, copies: false, nOctaves: 3)
        defer { copied.forEach { mat_wrapper_release($0) } }
        for (i, m) in direct.enumerated() {
            XCTAssertTrue(mat_wrapper_has_refcounted_buffer(m), "level \(i) lost its buffer owner")
        }
        // An ordinary Mat made by mat_wrapper_new is refcounted too; the distinction is the pool.
        let before = GPUOps.readbackPoolCounts()
        direct.forEach { mat_wrapper_release($0) }
        let after = GPUOps.readbackPoolCounts()
        XCTAssertEqual((after.returned + after.dropped) - (before.returned + before.dropped), direct.count,
                       "releasing the Mats must give every readback buffer back exactly once")
    }

    /// A pyramid the CPU still holds must not be overwritten by the next build.
    func testALivePyramidIsNotReusedByTheNextBuild() throws {
        let a = floatImage(width: 320, height: 240, seed: 11)
        let b = floatImage(width: 320, height: 240, seed: 99)
        defer { mat_wrapper_release(a); mat_wrapper_release(b) }
        let reference = try buildSift(a, copies: true, nOctaves: 3)
        let held = try buildSift(a, copies: false, nOctaves: 3)
        let other = try buildSift(b, copies: false, nOctaves: 3)
        defer { (reference + held + other).forEach { mat_wrapper_release($0) } }
        for (i, (r, h)) in zip(reference, held).enumerated() {
            XCTAssertTrue(bytes(of: r) == bytes(of: h), "level \(i) of a live pyramid changed under a later build")
        }
    }

    /// The whole detector, both ways: same keypoints, same descriptors, byte for byte on disk.
    func testSIFTKeypointsAndDescriptorsAreIdenticalBothWays() throws {
        let img = starField(width: 640, height: 480, count: 60)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [Data] = []
        for copies in [true, false] {
            GPUOps.setReadbackCopies(copies)
            let set = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 800))
            XCTAssertGreaterThan(set.keypointCount, 20)
            let path = dir.appendingPathComponent("sift-\(copies).kp").path
            XCTAssertTrue(set.write(toFilename: path))
            files.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        XCTAssertTrue(files[0] == files[1], "SIFT output differs between copy and zero-copy readback")
    }

    func testAKAZEKeypointsAndDescriptorsAreIdenticalBothWays() throws {
        try XCTSkipUnless(gpu_ops_akaze_pyramid_available(), "no GPU AKAZE pyramid handler registered")
        let img = starField(width: 640, height: 480, count: 60)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r7-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [Data] = []
        for copies in [true, false] {
            GPUOps.setReadbackCopies(copies)
            let set = try XCTUnwrap(ImageAligner.debugAkazeGPU(img, mask: nil, maxKeypoints: 800, threshold: 0.001))
            XCTAssertGreaterThan(set.keypointCount, 20)
            let path = dir.appendingPathComponent("akaze-\(copies).kp").path
            XCTAssertTrue(set.write(toFilename: path))
            files.append(try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        XCTAssertTrue(files[0] == files[1], "AKAZE output differs between copy and zero-copy readback")
    }

    /// Footprint must not climb build over build: every buffer comes back when its Mats die.
    func testRepeatedZeroCopyBuildsDoNotAccumulateBuffers() throws {
        GPUOps.setReadbackCopies(false)
        let img = starField(width: 1536, height: 1024, count: 200)
        _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 1000))
        let before = residentFootprint()
        for _ in 0..<6 { _ = try XCTUnwrap(ImageAligner.debugSiftGPU(img, mask: nil, nfeatures: 1000)) }
        let now = residentFootprint()
        let growth = now > before ? now - before : 0
        XCTAssertLessThan(growth, UInt64(1536 * 1024) * 32, "6 builds grew the footprint by \(growth / 1_048_576)MB")
    }

    private func residentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private func starField(width: Int, height: Int, count: Int) -> MatWrapper {
        var state: UInt64 = 1
        func next() -> UInt32 { state = state &* 6364136223846793005 &+ 1442695040888963407; return UInt32(state >> 33) }
        var pixels = [UInt8](repeating: 4, count: width * height)
        for _ in 0..<count {
            let cx = Int(next() % UInt32(width)), cy = Int(next() % UInt32(height))
            let radius = 4 + Int(next() % 14)
            for dy in -radius...radius { for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                let x = cx + dx, y = cy + dy
                if x >= 0, x < width, y >= 0, y < height { pixels[y * width + x] = 250 }
            } }
        }
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        data.update(from: pixels, count: width * height)
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }
}
