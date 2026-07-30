import XCTest
@testable import StarCore

/// `SortablePixel` is the monochrome pixel the blobber works in.  One is allocated per
/// outlier pixel, so the type is deliberately small, and its value is an enum over the three
/// bit depths star supports.  The conversions between those depths are what the blob
/// thresholds are compared against.
final class SortablePixelTests: XCTestCase {

    // MARK: - intensity normalisation

    /// `intensity` normalises each depth onto 0...1, which is what lets one threshold work
    /// across 8, 16 and 32 bit sources.
    func testIntensityNormalisesEachDepthOntoTheSameScale() {
        XCTAssertEqual(SortablePixel(value: .eightBit(0)).intensity, 0)
        XCTAssertEqual(SortablePixel(value: .eightBit(0xFF)).intensity, 1)
        XCTAssertEqual(SortablePixel(value: .eightBit(0x80)).intensity, 128.0 / 255.0, accuracy: 1e-12)

        XCTAssertEqual(SortablePixel(value: .sixteenBit(0)).intensity, 0)
        XCTAssertEqual(SortablePixel(value: .sixteenBit(0xFFFF)).intensity, 1)
        XCTAssertEqual(SortablePixel(value: .sixteenBit(0x8000)).intensity, 32768.0 / 65535.0, accuracy: 1e-12)
    }

    /// The same brightness expressed at two depths normalises to the same number, which is the
    /// property that makes the thresholds portable.  The exact correspondence is the 0x101
    /// scaling that maps 8 bit onto 16 bit (0xFF -> 0xFFFF), not a plain shift — 0x7F and
    /// 0x7FFF are *not* the same brightness, and differ by about 0.002 here.
    func testTheSameBrightnessAtTwoDepthsNormalisesIdentically() {
        for eightBitValue in [UInt8(0), 1, 0x40, 0x7F, 0x80, 0xFE, 0xFF] {
            let eight = SortablePixel(value: .eightBit(eightBitValue)).intensity
            let widened = UInt16(eightBitValue) * 0x101
            let sixteen = SortablePixel(value: .sixteenBit(widened)).intensity
            XCTAssertEqual(eight, sixteen, accuracy: 1e-12,
                           "8 bit \(eightBitValue) and 16 bit \(widened) are the same brightness")
        }
    }

    func testTheExtremesLineUpAcrossDepths() {
        XCTAssertEqual(SortablePixel(value: .eightBit(0)).intensity,
                       SortablePixel(value: .sixteenBit(0)).intensity)
        XCTAssertEqual(SortablePixel(value: .eightBit(0xFF)).intensity,
                       SortablePixel(value: .sixteenBit(0xFFFF)).intensity, accuracy: 1e-12)
    }

    func testIntensityIsMonotonic() {
        var previous = -1.0
        for value in [UInt16(0), 1, 100, 1000, 0x8000, 0xFFFE, 0xFFFF] {
            let intensity = SortablePixel(value: .sixteenBit(value)).intensity
            XCTAssertGreaterThan(intensity, previous, "intensity did not rise at \(value)")
            previous = intensity
        }
    }

    func testThirtyTwoBitIntensityNormalisesAgainstThe32BitMaximum() {
        XCTAssertEqual(SortablePixel(value: .thirtyTwoBit(0)).intensity, 0)
        let value: Int32 = 1 << 30
        XCTAssertEqual(SortablePixel(value: .thirtyTwoBit(value)).intensity,
                       Double(value) / 0xFFFFFFFF, accuracy: 1e-12)
    }

    // MARK: - raw value access

    func testTheWidenedValueCarriesEachDepthUnchanged() {
        XCTAssertEqual(SortablePixel(value: .eightBit(200)).uInt32Value, 200)
        XCTAssertEqual(SortablePixel(value: .sixteenBit(60000)).uInt32Value, 60000)
        XCTAssertEqual(SortablePixel(value: .thirtyTwoBit(123456)).uInt32Value, 123456)
    }

    func testTheSixteenBitAccessorWidensEightBitsWithoutScaling() {
        // 8 bit 255 becomes 16 bit 255, not 65535 — this is a widening, not a rescale
        XCTAssertEqual(SortablePixel(value: .eightBit(0xFF)).uInt16Value, 255)
        XCTAssertEqual(SortablePixel(value: .sixteenBit(0xFFFF)).uInt16Value, 0xFFFF)
    }

    // MARK: - contrast

    func testAPixelHasNoContrastWithItself() {
        let pixel = SortablePixel(value: .sixteenBit(1000))
        XCTAssertEqual(pixel.contrast(with: pixel), 0)
    }

    /// The documented scale: 50 when one value is twice the other, 100 when one is zero.
    func testDoubleTheValueIsFiftyPercentContrast() {
        let dim = SortablePixel(value: .sixteenBit(1000))
        let bright = SortablePixel(value: .sixteenBit(2000))
        XCTAssertEqual(dim.contrast(with: bright), 50, accuracy: 1e-9)
    }

    func testZeroAgainstAnythingIsFullContrast() {
        let dark = SortablePixel(value: .sixteenBit(0))
        let bright = SortablePixel(value: .sixteenBit(1234))
        XCTAssertEqual(dark.contrast(with: bright), 100, accuracy: 1e-9)
    }

    func testContrastIsSymmetric() {
        let a = SortablePixel(value: .sixteenBit(300))
        let b = SortablePixel(value: .sixteenBit(900))
        XCTAssertEqual(a.contrast(with: b), b.contrast(with: a), accuracy: 1e-12)
    }

    func testContrastRisesWithSeparation() {
        let base = SortablePixel(value: .sixteenBit(1000))
        var previous = -1.0
        for other in [UInt16(1000), 1200, 1500, 2000, 5000, 60000] {
            let contrast = base.contrast(with: SortablePixel(value: .sixteenBit(other)))
            XCTAssertGreaterThan(contrast, previous, "contrast did not rise at \(other)")
            previous = contrast
        }
    }

    func testContrastStaysWithinItsStatedRange() {
        for a in [UInt16(0), 1, 100, 5000, 0xFFFF] {
            for b in [UInt16(1), 100, 5000, 0xFFFF] {
                let contrast = SortablePixel(value: .sixteenBit(a))
                    .contrast(with: SortablePixel(value: .sixteenBit(b)))
                XCTAssertGreaterThanOrEqual(contrast, 0)
                XCTAssertLessThanOrEqual(contrast, 100)
            }
        }
    }

    /// Two black pixels divide zero by zero.  The blobber only asks about pixels it has
    /// already decided are bright, so it does not hit this, but the NaN would propagate
    /// silently into a comparison that is false either way.
    func testTwoBlackPixelsGiveNaNRatherThanZero() {
        let black = SortablePixel(value: .sixteenBit(0))
        XCTAssertTrue(black.contrast(with: black).isNaN,
                      "if this is now 0, the division was guarded — update this test")
    }

    // MARK: - identity is positional

    /// `==` and `hash(into:)` use only x and y, so two pixels at the same place are the same
    /// pixel whatever their values.  That is what lets the blobber keep a `Set` of positions,
    /// but it also means a Set cannot hold two readings of one pixel.
    func testTwoPixelsAtOnePositionAreEqualRegardlessOfValue() {
        let dim = SortablePixel(x: 5, y: 7, value: .sixteenBit(1))
        let bright = SortablePixel(x: 5, y: 7, value: .sixteenBit(60000))

        XCTAssertEqual(dim, bright)
        XCTAssertEqual(dim.hashValue, bright.hashValue)
        XCTAssertEqual(Set([dim, bright]).count, 1)
    }

    func testPixelsAtDifferentPositionsAreNotEqual() {
        let a = SortablePixel(x: 5, y: 7, value: .eightBit(1))
        XCTAssertNotEqual(a, SortablePixel(x: 6, y: 7, value: .eightBit(1)))
        XCTAssertNotEqual(a, SortablePixel(x: 5, y: 8, value: .eightBit(1)))
    }

    /// x and y are not interchangeable in the hash — if they were, [1, 2] and [2, 1] would
    /// collide, and a whole diagonal of the image would hash together.
    func testTransposedPositionsDoNotCollide() {
        let a = SortablePixel(x: 1, y: 2, value: .eightBit(0))
        let b = SortablePixel(x: 2, y: 1, value: .eightBit(0))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 2)
    }

    func testASetOfManyPositionsKeepsThemAllApart() {
        var pixels: Set<SortablePixel> = []
        for x in 0..<20 {
            for y in 0..<20 {
                pixels.insert(SortablePixel(x: x, y: y, value: .eightBit(UInt8(x % 256))))
            }
        }
        XCTAssertEqual(pixels.count, 400)
    }

    func testTheDefaultPositionIsTheOrigin() {
        let pixel = SortablePixel(value: .eightBit(1))
        XCTAssertEqual(pixel.x, 0)
        XCTAssertEqual(pixel.y, 0)
    }

    // MARK: - id

    /// `id` encodes the position into one number using a stride wider than any real image, so
    /// that distinct positions never produce the same id.
    func testTheIdIsUniquePerPosition() {
        var ids: Set<String> = []
        for x in 0..<50 {
            for y in 0..<50 {
                ids.insert(SortablePixel(x: x, y: y, value: .eightBit(0)).id)
            }
        }
        XCTAssertEqual(ids.count, 2500)
    }

    func testTheIdDoesNotDependOnTheValue() {
        XCTAssertEqual(SortablePixel(x: 3, y: 4, value: .eightBit(0)).id,
                       SortablePixel(x: 3, y: 4, value: .sixteenBit(9999)).id)
    }

    func testTheOriginHasIdZero() {
        XCTAssertEqual(SortablePixel(x: 0, y: 0, value: .eightBit(0)).id, "0")
    }

    /// The stride has to exceed any plausible image width, or two positions on adjacent rows
    /// would share an id.  A 40000 pixel wide frame is far past anything real.
    func testTheIdStrideSurvivesAbsurdlyWideImages() {
        let farRight = SortablePixel(x: 40_000, y: 0, value: .eightBit(0))
        let nextRow = SortablePixel(x: 0, y: 1, value: .eightBit(0))
        XCTAssertNotEqual(farRight.id, nextRow.id)
    }

    // MARK: - description

    func testDescriptionIsThePosition() {
        XCTAssertEqual(SortablePixel(x: 12, y: 34, value: .eightBit(0)).description, "[12, 34]")
    }

    // MARK: - Status equality

    func testStatusDistinguishesUnknownFromBackground() {
        XCTAssertTrue(SortablePixel.Status.unknown == SortablePixel.Status.unknown)
        XCTAssertTrue(SortablePixel.Status.background == SortablePixel.Status.background)
        XCTAssertFalse(SortablePixel.Status.unknown == SortablePixel.Status.background)
        XCTAssertTrue(SortablePixel.Status.unknown != SortablePixel.Status.background)
    }

    func testABlobbedStatusIsNeitherUnknownNorBackground() async {
        let blob = Blob(SortablePixel(x: 1, y: 1, value: .eightBit(9)), id: 1, frameIndex: 0)
        let blobbed = SortablePixel.Status.blobbed(blob)

        XCTAssertFalse(blobbed == .unknown)
        XCTAssertFalse(blobbed == .background)
        XCTAssertFalse(SortablePixel.Status.unknown == blobbed)
    }

    /// Blobbed statuses compare by blob id, so the same blob is recognised through two
    /// separate `Status` values.
    func testTwoStatusesForOneBlobAreEqual() async {
        let blob = Blob(SortablePixel(x: 1, y: 1, value: .eightBit(9)), id: 1, frameIndex: 0)
        XCTAssertTrue(SortablePixel.Status.blobbed(blob) == .blobbed(blob))
    }

    func testStatusesForDifferentBlobsAreNotEqual() async {
        let one = Blob(SortablePixel(x: 1, y: 1, value: .eightBit(9)), id: 1, frameIndex: 0)
        let two = Blob(SortablePixel(x: 2, y: 2, value: .eightBit(9)), id: 2, frameIndex: 0)
        XCTAssertFalse(SortablePixel.Status.blobbed(one) == .blobbed(two))
        XCTAssertTrue(SortablePixel.Status.blobbed(one) != .blobbed(two))
    }
}
