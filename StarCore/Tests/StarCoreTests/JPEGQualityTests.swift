import XCTest
@testable import StarCore
import StarCppBridge

final class JPEGQualityTests: XCTestCase {
    static func noisyImage(width: Int = 64, height: Int = 64) -> PixelatedImage? {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        var seed: UInt32 = 12345
        for i in 0..<count { seed = seed &* 1664525 &+ 1013904223; data[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 3),
                             bytesPerRow: width * 3, data: UnsafeMutableRawPointer(data), takeOwnership: true)
        return PixelatedImage(mat: mat)
    }

    func testEstimateMatchesWriter() throws {
        let dir = NSTemporaryDirectory() + "JPEGQualityTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let image = try XCTUnwrap(Self.noisyImage())
        for quality in [50, 80, 90, 95] {
            let path = "\(dir)/q\(quality).jpg"
            XCTAssertTrue(image.saveJpeg(withQuality: UInt(quality), filename: path))
            let estimate = try XCTUnwrap(JPEGQuality.estimate(atPath: path))
            XCTAssertLessThanOrEqual(abs(estimate - quality), 2, "wrote \(quality), estimated \(estimate)")
        }
    }

    func testNotAJPEGHasNoEstimate() throws {
        let path = NSTemporaryDirectory() + "notjpeg-\(UUID().uuidString).txt"
        try "hello world, not a jpeg".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(JPEGQuality.estimate(atPath: path))
    }
}
