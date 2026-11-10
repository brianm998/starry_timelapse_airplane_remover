import XCTest
import StarCppBridge
@testable import StarCore

/// `ImageSequence.getImageInfo()` is where every client learns a sequence's format, so it is where a depth the
/// later stages cannot process (they `fatalError` on it) has to be refused.
final class ImageSequenceInfoTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "ImageSequenceInfoTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Writes a 4x3 single channel frame of `bits` bits per component (32 is float) as `<dir>/frame_0001.tiff`.
    private func writeFrame(bits: Int32) throws {
        let width = 4, height = 3
        let cvType = MatWrapper.cvType(forBitsPerComponent: bits, componentsPerPixel: 1)
        let bytesPerRow = width * Int(bits / 8)
        var bytes = [UInt8](repeating: 0x40, count: bytesPerRow * height)
        if bits == 32 {
            let floats = [Float](repeating: 0.5, count: width * height)
            bytes = floats.withUnsafeBytes { Array($0) }
        }
        let written = bytes.withUnsafeMutableBytes { buffer in
            MatWrapper(width: width, height: height, cvType: cvType, bytesPerRow: bytesPerRow,
                       data: buffer.baseAddress!, takeOwnership: false)
                .write(to: "\(dir!)/frame_0001.tiff")
        }
        XCTAssertTrue(written)
    }

    private func sequence() throws -> ImageSequence {
        try ImageSequence(dirname: dir, supportedImageFileTypes: [".tiff"])
    }

    func testThirtyTwoBitSequenceIsRejected() async throws {
        try writeFrame(bits: 32)
        do {
            _ = try await sequence().getImageInfo()
            XCTFail("a 32 bit sequence should not open")
        } catch {
            let message = "\(error)"
            XCTAssertEqual(message, localized("ui.unsupported_bit_depth", 32))
            XCTAssertTrue(message.contains("32"), message)
            XCTAssertTrue(message.contains("8") && message.contains("16"), message)
        }
    }

    func testEightAndSixteenBitStillOpen() async throws {
        for bits: Int32 in [8, 16] {
            try writeFrame(bits: bits)
            let info = try await sequence().getImageInfo()
            XCTAssertEqual(info.imageBitsPerComponent, Int(bits))
            XCTAssertEqual(info.imageWidth, 4)
            XCTAssertEqual(info.imageHeight, 3)
            XCTAssertEqual(info.componentsPerPixel, 1)
            XCTAssertEqual(info.imageBytesPerPixel, Int(bits / 8))
            XCTAssertEqual(info.fileExtension, "tiff")
            try FileManager.default.removeItem(atPath: "\(dir!)/frame_0001.tiff")
        }
    }
}
