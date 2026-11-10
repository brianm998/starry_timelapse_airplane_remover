import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// An unsupported image depth in the blob stage must fail the frame, not end the process: these
/// sites used to `fatalError` inside functions that already throw.
final class BlobStageErrorTests: FrameHarnessTestCase {

    private static func thirtyTwoBitImage(width: Int, height: Int) -> PixelatedImage {
        // the bridge only builds a single channel 32 bit (float) mat
        let components = 1
        let data = UnsafeMutablePointer<Float>.allocate(capacity: width * height * components)
        data.initialize(repeating: 1000, count: width * height * components)
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 32,
                                                       componentsPerPixel: Int32(components)),
                             bytesPerRow: width * components * 4,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    /// A 32 bit subtraction image on disk never reaches the depth switch in `setup()`: `ensure16Bits`
    /// converts it first.  So this is the reachable behaviour of the "32 bit subtraction image" case:
    /// it loads as 16 bit and the frame goes on, neither terminating nor throwing.  The `throw`s in
    /// the switch itself only guard a failed conversion, which a test cannot provoke.
    func testThirtyTwoBitSubtractionImageIsConvertedNotFatal() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "blob32")
        harness = h
        try h.plantImage(Self.thirtyTwoBitImage(width: 128, height: 96), ofType: .subtraction)

        let processor = MildBlobProcessor()
        processor.frame = h.frame

        let array = try await processor.setup()
        XCTAssertEqual(array.count, 128 * 96)
    }

    func testMissingFrameThrows() async throws {
        let processor = MildBlobProcessor()
        do {
            _ = try await processor.setup()
            XCTFail("setup without a frame must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("frame"), "\(error)")
        }
    }
}
