import XCTest
@testable import StarCore
import StarCppBridge

/// The soft horizon composite: `blend(mask:with:)` reads the mask as alpha, and a
/// gradient mask from `raiseMaskBy` turns a brightness mismatch between the sky and
/// earth layers into a ramp instead of a line.
final class FeatheredCompositeTests: XCTestCase {

    private let width = 60
    private let height = 200

    private func uniform(_ value: UInt16) -> PixelatedImage {
        var pixels = [UInt16](repeating: value, count: width * height * 3)
        return pixels.withUnsafeMutableBytes { ptr in
            PixelatedImage(mat: MatWrapper(
              width: width, height: height,
              cvType: 18, // CV_16UC3
              bytesPerRow: width * 6,
              data: ptr.baseAddress!,
              takeOwnership: false
            ).clone())!
        }
    }

    private func value(_ image: PixelatedImage, _ x: Int, _ y: Int) -> UInt16 {
        guard case .sixteenBit(let buffer) = image.imageData else {
            XCTFail("expected 16 bit data")
            return 0
        }
        return buffer[(y * width + x) * 3]
    }

    func testAGradientMaskRampsBetweenTheLayers() throws {
        // sky and earth deliberately mismatched, the way two different temporal
        // medians are at twilight
        let sky = uniform(20000)
        let earth = uniform(30000)
        let boundary = 120
        let feather = 24
        let mask = try XCTUnwrap(
          PixelatedImage.fromHorizonColumnY(
            width: width, height: height,
            columnY: [Int?](repeating: boundary, count: width))
        )
        let feathered = try XCTUnwrap(mask.raiseMaskBy(feather))
        let composite = try sky.blend(mask: feathered, with: earth)

        // pure earth below the boundary, pure sky above the ramp
        XCTAssertEqual(value(composite, 30, boundary + 10), 30000)
        XCTAssertEqual(value(composite, 30, boundary - feather - 10), 20000)

        // and a monotonic ramp between them, never a step: adjacent rows through
        // the transition may differ by only a few percent of the layer gap
        var previous = Int(value(composite, 30, boundary + 2))
        for y in stride(from: boundary + 1, through: boundary - feather - 2, by: -1) {
            let current = Int(value(composite, 30, y))
            XCTAssertLessThanOrEqual(current, previous,
                                     "y \(y): the ramp has to descend toward the sky value")
            XCTAssertLessThanOrEqual(previous - current, 1500,
                                     "y \(y): feathering exists to remove steps, " +
                                     "not to move one")
            previous = current
        }
    }

    func testABinaryMaskStillActsAsAHardSwitch() throws {
        let sky = uniform(20000)
        let earth = uniform(30000)
        let boundary = 120
        let mask = try XCTUnwrap(
          PixelatedImage.fromHorizonColumnY(
            width: width, height: height,
            columnY: [Int?](repeating: boundary, count: width))
        )
        let composite = try sky.blend(mask: mask, with: earth)
        XCTAssertEqual(value(composite, 30, boundary), 30000)
        XCTAssertEqual(value(composite, 30, boundary - 1), 20000)
    }
}
