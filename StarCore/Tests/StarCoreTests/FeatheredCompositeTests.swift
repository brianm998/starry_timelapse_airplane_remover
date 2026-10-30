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

    // MARK: - the earth above the mask's first row below 255 is never read

    private func image(_ pixels: [UInt16]) -> PixelatedImage {
        var copy = pixels
        return copy.withUnsafeMutableBytes { ptr in
            PixelatedImage(mat: MatWrapper(
              width: width, height: height,
              cvType: 18, // CV_16UC3
              bytesPerRow: width * 6,
              data: ptr.baseAddress!,
              takeOwnership: false
            ).clone())!
        }
    }

    private func samples(_ image: PixelatedImage) -> [UInt16] {
        guard case .sixteenBit(let buffer) = image.imageData else {
            XCTFail("expected 16 bit data")
            return []
        }
        return Array(buffer)
    }

    /// The band-limited earth merge (`Config.bandLimitedEarthMerge`) merges the earth only from the first
    /// row where the feathered mask holds a value below 255 — above it the earth image is the base frame's own.
    /// That is only allowed because the composite never reads the earth there: at alpha 255 the blend copies
    /// the sky pixel whole, and a row with a partial alpha elsewhere computes sky·w + earth·(1 − w), which at
    /// w = 1 is the sky exactly.  This replaces every earth row above that row with something else and
    /// requires the composite not to move by a bit — through the feathered blend, and through the hard-mask
    /// fallback the composite takes if the feathering fails (which needs a subset of those rows).
    func testTheEarthAboveTheMasksFirstRowBelow255IsNeverRead() throws {
        var state: UInt64 = 0xC0FF_EE15_600D
        func next() -> UInt16 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt16(truncatingIfNeeded: state >> 40)
        }
        let skyPixels = (0..<(width * height * 3)).map { _ in next() }
        let earthPixels = (0..<(width * height * 3)).map { _ in next() }

        // a wavy horizon, so the feathered mask has partial values in many rows
        var columnY = [Int?](repeating: 0, count: width)
        for x in 0..<width {
            let wave: Int = Int(10.0 * sin(Double(x) / 7.0))
            columnY[x] = 110 + wave
        }
        let mask = try XCTUnwrap(PixelatedImage.fromHorizonColumnY(width: width, height: height, columnY: columnY))
        let feathered = try XCTUnwrap(mask.raiseMaskBy(24))
        let firstRow = ImageAligner.firstRow(of: feathered.mat, below: 255)
        XCTAssertGreaterThan(firstRow, 0, "the mask has sky rows at 255 above its feather")
        XCTAssertLessThan(firstRow, height, "and rows below")

        // earth rows above `firstRow` replaced by garbage that is nothing like them
        var garbage = earthPixels
        for i in 0..<(firstRow * width * 3) { garbage[i] = next() ^ 0xA5A5 }

        let sky = image(skyPixels), earth = image(earthPixels), changedEarth = image(garbage)
        XCTAssertNotEqual(samples(earth), samples(changedEarth))

        let whole = try sky.blend(mask: feathered, with: earth)
        let banded = try sky.blend(mask: feathered, with: changedEarth)
        XCTAssertEqual(samples(whole), samples(banded), "the feathered blend read an earth row above the first row below 255")

        let hardWhole = try sky.apply(mask: mask, with: earth)
        let hardBanded = try sky.apply(mask: mask, with: changedEarth)
        XCTAssertEqual(samples(hardWhole), samples(hardBanded), "the hard-mask fallback read an earth row above the band")
    }
}
