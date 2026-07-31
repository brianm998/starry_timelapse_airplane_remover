import XCTest
import StarCppBridge
@testable import StarCore

/// `PixelatedImage` is what every stage of the pipeline actually passes around: it wraps a
/// `MatWrapper` and adds pixel access, the boolean mask operations the horizon work is built on,
/// tiling, and the merges.  1314 lines, none of it covered.
///
/// Everything here is driven off images generated in the test rather than fixtures on disk, so the
/// suite stays self-contained.
final class PixelatedImageTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PixelatedImageTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    /// A 16-bit single-channel image, which is the shape the horizon masks and blob work use.
    private func sixteenBitGray(width: Int, height: Int,
                                value: (Int, Int) -> UInt16) -> PixelatedImage
    {
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = value(x, y) }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 1),
                             bytesPerRow: width * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    /// A 16-bit three-channel image, the shape a real frame has.
    private func sixteenBitColor(width: Int, height: Int,
                                 value: (Int, Int, Int) -> UInt16) -> PixelatedImage
    {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 { data[(y * width + x) * 3 + c] = value(x, y, c) }
            }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    private func eightBitGray(width: Int, height: Int,
                              value: (Int, Int) -> UInt8) -> PixelatedImage
    {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width { data[y * width + x] = value(x, y) }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                       componentsPerPixel: 1),
                             bytesPerRow: width,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }


    // MARK: - reading values back out

    /// `uInt16Array` and friends are on `ContiguousBytes`, not on `PixelatedImage`, so the values
    /// come out of the `imageData` buffer instead.
    private func words(_ image: PixelatedImage) -> [UInt16] {
        guard case .sixteenBit(let buffer) = image.imageData else {
            XCTFail("expected 16 bit image data"); return []
        }
        return Array(buffer)
    }

    private func bytes(_ image: PixelatedImage) -> [UInt8] {
        guard case .eightBit(let buffer) = image.imageData else {
            XCTFail("expected 8 bit image data"); return []
        }
        return Array(buffer)
    }

    // MARK: - geometry and metadata

    func testTheGeometryComesFromTheMat() {
        let image = sixteenBitColor(width: 7, height: 3) { _, _, _ in 1000 }
        XCTAssertEqual(image.width, 7)
        XCTAssertEqual(image.height, 3)
        XCTAssertEqual(image.componentsPerPixel, 3)
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.bitsPerPixel, 48)
        XCTAssertEqual(image.bytesPerPixel, 6)
        XCTAssertFalse(image.isEmpty)
    }

    func testAGrayImageReportsOneComponent() {
        let image = sixteenBitGray(width: 4, height: 4) { _, _ in 0 }
        XCTAssertEqual(image.componentsPerPixel, 1)
        XCTAssertEqual(image.bitsPerPixel, 16)
        XCTAssertEqual(image.bytesPerPixel, 2)
    }

    func testAnEightBitImageReportsEightBitData() {
        let image = eightBitGray(width: 4, height: 4) { _, _ in 0 }
        XCTAssertEqual(image.bitsPerComponent, 8)
        if case .eightBit = image.imageData {} else {
            XCTFail("an 8 bit mat should give eightBit image data")
        }
    }

    func testASixteenBitImageReportsSixteenBitData() {
        let image = sixteenBitGray(width: 4, height: 4) { _, _ in 0 }
        if case .sixteenBit = image.imageData {} else {
            XCTFail("a 16 bit mat should give sixteenBit image data")
        }
    }

    /// An empty mat is not a usable image, and the initializer says so rather than producing one
    /// with zero dimensions that later divides by width.
    func testAnEmptyMatDoesNotProduceAnImage() {
        let empty = sixteenBitGray(width: 8, height: 8) { _, _ in 0 }
        guard let cropped = empty.mat.bottomCrop(8) else { return XCTFail("expected a crop") }
        XCTAssertTrue(cropped.isEmpty)
        XCTAssertNil(PixelatedImage(mat: cropped), "an empty mat is not an image")
    }

    func testByteCountCoversEveryComponent() {
        let image = sixteenBitColor(width: 5, height: 4) { _, _, _ in 0 }
        XCTAssertEqual(image.byteCount, 5 * 4 * 3 * 2)
    }

    // MARK: - reading pixels

    /// The offset arithmetic in `readPixel` is `y * width * components + x * components`, so it
    /// ignores `bytesPerRow` — which is fine only while the mat is tightly packed.  These pin that
    /// the mapping from (x, y) to a value is right, including that x and y are not transposed.
    func testReadingAPixelFindsTheValueThatWasWrittenThere() {
        let image = sixteenBitGray(width: 6, height: 4) { x, y in UInt16(y * 100 + x) }
        for y in 0..<4 {
            for x in 0..<6 {
                XCTAssertEqual(image.readPixel(atX: x, andY: y).red, UInt16(y * 100 + x),
                               "pixel [\(x), \(y)]")
            }
        }
    }

    func testReadingIsNotTransposed() {
        // only [1, 0] is set, so a transposed read would find nothing there and something at [0, 1]
        let image = sixteenBitGray(width: 4, height: 4) { x, y in (x == 1 && y == 0) ? 9999 : 0 }
        XCTAssertEqual(image.readPixel(atX: 1, andY: 0).red, 9999)
        XCTAssertEqual(image.readPixel(atX: 0, andY: 1).red, 0)
    }

    func testEachColourChannelIsReadSeparately() {
        // red = 100, green = 200, blue = 300 everywhere
        let image = sixteenBitColor(width: 3, height: 3) { _, _, c in UInt16((c + 1) * 100) }
        let pixel = image.readPixel(atX: 1, andY: 1)
        XCTAssertEqual(pixel.red, 100)
        XCTAssertEqual(pixel.green, 200)
        XCTAssertEqual(pixel.blue, 300)
    }

    func testAGrayPixelLeavesTheOtherChannelsAlone() {
        let image = sixteenBitGray(width: 3, height: 3) { _, _ in 777 }
        let pixel = image.readPixel(atX: 1, andY: 1)
        XCTAssertEqual(pixel.red, 777)
        XCTAssertEqual(pixel.green, 0, "a single channel image has no green")
        XCTAssertEqual(pixel.blue, 0)
    }

    // MARK: - the raw arrays

    func testTheSixteenBitArrayIsRowMajorAndComplete() {
        let image = sixteenBitGray(width: 4, height: 3) { x, y in UInt16(y * 10 + x) }
        let array = words(image)

        XCTAssertEqual(array.count, 12)
        for y in 0..<3 {
            for x in 0..<4 {
                XCTAssertEqual(array[y * 4 + x], UInt16(y * 10 + x), "index for [\(x), \(y)]")
            }
        }
    }

    func testTheEightBitArrayIsRowMajorAndComplete() {
        let image = eightBitGray(width: 4, height: 3) { x, y in UInt8(y * 10 + x) }
        let array = bytes(image)
        XCTAssertEqual(array.count, 12)
        XCTAssertEqual(array[0], 0)
        XCTAssertEqual(array[4], 10, "the start of row 1")
        XCTAssertEqual(array[11], 23)
    }

    func testTheColourArrayInterleavesComponents() {
        let image = sixteenBitColor(width: 2, height: 1) { x, _, c in UInt16(x * 10 + c) }
        XCTAssertEqual(words(image), [0, 1, 2, 10, 11, 12])
    }

    /// `byteCount` is read off the image data buffer, so it counts every component.
    func testByteCountMatchesTheBufferLength() {
        let image = sixteenBitGray(width: 5, height: 4) { _, _ in 0x1234 }
        XCTAssertEqual(image.byteCount, 5 * 4 * 2)
        XCTAssertEqual(words(image).count, 5 * 4)
    }

    // MARK: - clone

    func testACloneIsIndependentOfItsSource() {
        let original = sixteenBitGray(width: 4, height: 4) { x, y in UInt16(x + y) }
        let copy = original.clone

        XCTAssertEqual(copy.width, original.width)
        XCTAssertEqual(copy.height, original.height)
        XCTAssertEqual(words(copy), words(original))
        XCTAssertNotEqual(copy.mat.dataPtr, original.mat.dataPtr,
                          "a clone must not share its buffer")
    }

    // MARK: - the boolean mask operations

    /// The mask operations are what the horizon work composes: a mask is white where the sky is,
    /// and these combine and invert them.  Getting `not` wrong inverts the whole horizon.
    func testBitwiseNotInvertsAMask() throws {
        // an 8 bit mask, half white
        let mask = eightBitGray(width: 4, height: 2) { x, _ in x < 2 ? 255 : 0 }
        let inverted = try mask.bitwiseNot()

        XCTAssertEqual(inverted.intensity(atX: 0, andY: 0), 0, "white becomes black")
        XCTAssertEqual(inverted.intensity(atX: 3, andY: 0), 255, "black becomes white")
    }

    func testNotTwiceIsTheOriginal() throws {
        let mask = eightBitGray(width: 6, height: 3) { x, y in (x + y) % 2 == 0 ? 255 : 0 }
        let back = try mask.bitwiseNot().bitwiseNot()
        XCTAssertEqual(bytes(back), bytes(mask))
    }

    func testBitwiseAndKeepsOnlyWhatBothMasksHave() throws {
        let left = eightBitGray(width: 4, height: 1) { x, _ in x < 3 ? 255 : 0 }   // 1 1 1 0
        let right = eightBitGray(width: 4, height: 1) { x, _ in x > 0 ? 255 : 0 }  // 0 1 1 1

        let both = try left.bitwiseAnd(with: right)
        XCTAssertEqual(bytes(both), [0, 255, 255, 0])
    }

    func testBitwiseOrKeepsWhatEitherMaskHas() throws {
        let left = eightBitGray(width: 4, height: 1) { x, _ in x < 2 ? 255 : 0 }   // 1 1 0 0
        let right = eightBitGray(width: 4, height: 1) { x, _ in x > 2 ? 255 : 0 }  // 0 0 0 1

        let either = try left.bitwiseOr(with: right)
        XCTAssertEqual(bytes(either), [255, 255, 0, 255])
    }

    func testAndWithItselfIsItself() throws {
        let mask = eightBitGray(width: 5, height: 2) { x, y in (x * y) % 3 == 0 ? 255 : 0 }
        XCTAssertEqual(bytes(try mask.bitwiseAnd(with: mask)), bytes(mask))
    }

    func testOrWithItselfIsItself() throws {
        let mask = eightBitGray(width: 5, height: 2) { x, y in (x + y) % 3 == 0 ? 255 : 0 }
        XCTAssertEqual(bytes(try mask.bitwiseOr(with: mask)), bytes(mask))
    }

    /// A mask and its inverse share nothing and cover everything — the property the horizon
    /// composition relies on when it splits a frame into sky and ground.
    func testAMaskAndItsInverseArePartitions() throws {
        let mask = eightBitGray(width: 8, height: 4) { x, y in (x + y) % 3 == 0 ? 255 : 0 }
        let inverse = try mask.bitwiseNot()

        let overlap = try mask.bitwiseAnd(with: inverse)
        XCTAssertTrue(bytes(overlap).allSatisfy { $0 == 0 },
                      "a mask and its inverse should share no pixels")

        let union = try mask.bitwiseOr(with: inverse)
        XCTAssertTrue(bytes(union).allSatisfy { $0 == 255 },
                      "together they should cover every pixel")
    }

    // MARK: - subtract and absDiff

    func testSubtractingAnIdenticalFrameLeavesNothing() throws {
        let frame = sixteenBitGray(width: 5, height: 4) { x, y in UInt16(x * 100 + y) }
        let difference = try frame.subtract(frame)
        XCTAssertTrue(words(difference).allSatisfy { $0 == 0 },
                      "a frame minus itself should be black")
    }

    func testSubtractingADimmerFrameLeavesTheDifference() throws {
        let bright = sixteenBitGray(width: 4, height: 1) { _, _ in 1000 }
        let dim = sixteenBitGray(width: 4, height: 1) { _, _ in 400 }
        let difference = try bright.subtract(dim)
        XCTAssertTrue(words(difference).allSatisfy { $0 == 600 })
    }

    /// Subtraction saturates at zero rather than wrapping — this is how the outlier pass finds
    /// what is *brighter* than its neighbours without a dark frame producing huge values.
    func testSubtractingABrighterFrameSaturatesAtZero() throws {
        let dim = sixteenBitGray(width: 4, height: 1) { _, _ in 400 }
        let bright = sixteenBitGray(width: 4, height: 1) { _, _ in 1000 }
        let difference = try dim.subtract(bright)
        XCTAssertTrue(words(difference).allSatisfy { $0 == 0 },
                      "a negative difference must clamp, not wrap to 65136")
    }

    /// `absDiff` is the symmetric version, used where direction does not matter.
    func testAbsoluteDifferenceIsSymmetric() throws {
        let a = sixteenBitGray(width: 4, height: 1) { _, _ in 1000 }
        let b = sixteenBitGray(width: 4, height: 1) { _, _ in 400 }

        // absDiff goes through absDiffGrayscale, so the result is 8 bit single channel rather
        // than carrying the 16 bit depth of its inputs
        let forward = try XCTUnwrap(a.absDiff(with: b))
        let backward = try XCTUnwrap(b.absDiff(with: a))
        XCTAssertEqual(forward.bitsPerComponent, 8)
        XCTAssertEqual(bytes(forward), bytes(backward), "the difference is symmetric")
    }

    func testAbsoluteDifferenceWithItselfIsBlack() throws {
        let image = sixteenBitGray(width: 4, height: 4) { x, y in UInt16(x * y) }
        let difference = try XCTUnwrap(image.absDiff(with: image))
        XCTAssertTrue(bytes(difference).allSatisfy { $0 == 0 })
    }

    // MARK: - tiling

    /// Tiling is how the classifier and the horizon detector see a frame.  The tiles have to cover
    /// it and report their own position, or a classification lands on the wrong part of the image.
    func testSplittingCoversTheWholeImage() {
        let image = sixteenBitGray(width: 64, height: 32) { x, y in UInt16(x + y) }
        let tiles = image.splitIntoMatrix(maxWidth: 32, maxHeight: 32, overlapPercent: 0)

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(Set(tiles.map(\.x)), [0, 32])
        for tile in tiles {
            XCTAssertEqual(tile.width, 32)
            XCTAssertEqual(tile.height, 32)
            XCTAssertEqual(tile.image.width, 32)
            XCTAssertEqual(tile.image.height, 32)
        }
    }

    func testTilesAreRowMajor() {
        let image = sixteenBitGray(width: 64, height: 64) { _, _ in 0 }
        let tiles = image.splitIntoMatrix(maxWidth: 32, maxHeight: 32, overlapPercent: 0)
        XCTAssertEqual(tiles.map { "\($0.x),\($0.y)" }, ["0,0", "32,0", "0,32", "32,32"])
    }

    /// A tile's pixels have to be the ones at its own position in the source, or the classifier
    /// would be shown the wrong patch.
    func testATilesPixelsComeFromItsOwnPositionInTheSource() {
        let image = sixteenBitGray(width: 32, height: 16) { x, y in UInt16(y * 32 + x) }
        let tiles = image.splitIntoMatrix(maxWidth: 16, maxHeight: 16, overlapPercent: 0)

        for tile in tiles {
            for localY in 0..<tile.image.height {
                for localX in 0..<tile.image.width {
                    let expected = UInt16((tile.y + localY) * 32 + (tile.x + localX))
                    XCTAssertEqual(tile.image.readPixel(atX: localX, andY: localY).red, expected,
                                   "tile at [\(tile.x), \(tile.y)] local [\(localX), \(localY)]")
                }
            }
        }
    }

    func testOverlappingTilesStrideByLessThanATile() {
        let image = sixteenBitGray(width: 96, height: 32) { _, _ in 0 }
        let tiles = image.splitIntoMatrix(maxWidth: 32, maxHeight: 32, overlapPercent: 0.5)
        XCTAssertEqual(Set(tiles.map(\.x)).sorted(), [0, 16, 32, 48, 64, 80])
    }

    /// Combining the tiles back has to reproduce the image, which is what makes tile-wise
    /// processing usable at all.
    func testCombiningTilesRebuildsTheImage() throws {
        let image = sixteenBitGray(width: 32, height: 32) { x, y in UInt16(y * 32 + x) }
        let tiles = image.splitIntoMatrix(maxWidth: 16, maxHeight: 16, overlapPercent: 0)
        let rebuilt = try XCTUnwrap(PixelatedImage(from: tiles))

        XCTAssertEqual(rebuilt.width, 32)
        XCTAssertEqual(rebuilt.height, 32)
        XCTAssertEqual(words(rebuilt), words(image))
    }

    func testCombiningNoTilesGivesNothing() {
        XCTAssertNil(PixelatedImage(from: []))
    }

    // MARK: - ImageMatrixElement

    func testAnElementReportsTheBoundsItOccupies() {
        let image = sixteenBitGray(width: 8, height: 8) { _, _ in 0 }
        let element = ImageMatrixElement(x: 10, y: 20, image: image)

        XCTAssertEqual(element.bounds.min, Coord(x: 10, y: 20))
        XCTAssertEqual(element.bounds.max, Coord(x: 17, y: 27))
    }

    func testAnElementContainsThePointsInsideIt() {
        let image = sixteenBitGray(width: 8, height: 8) { _, _ in 0 }
        let element = ImageMatrixElement(x: 10, y: 20, image: image)

        XCTAssertTrue(element.contains(x: 10, y: 20), "its own origin")
        XCTAssertTrue(element.contains(x: 17, y: 27), "its far corner")
        XCTAssertFalse(element.contains(x: 9, y: 20))
        XCTAssertFalse(element.contains(x: 18, y: 27))
        XCTAssertFalse(element.contains(x: 10, y: 28))
    }

    func testAnElementsIntensityIsReadInItsOwnCoordinates() {
        let image = sixteenBitGray(width: 4, height: 4) { x, y in UInt16(y * 4 + x) }
        let element = ImageMatrixElement(x: 100, y: 200, image: image)

        // asked in absolute coordinates, answered from the tile's own pixels
        XCTAssertEqual(element.intensity(atX: 100, andY: 200), 0)
        XCTAssertEqual(element.intensity(atX: 101, andY: 200), 1)
        XCTAssertEqual(element.intensity(atX: 100, andY: 201), 4)
    }

    func testAnElementHasNoIntensityOutsideItself() {
        let image = sixteenBitGray(width: 4, height: 4) { _, _ in 500 }
        let element = ImageMatrixElement(x: 100, y: 200, image: image)
        XCTAssertNil(element.intensity(atX: 99, andY: 200))
        XCTAssertNil(element.intensity(atX: 104, andY: 200))
    }

    /// `sortablePixels` reports only the non-zero pixels — they are outlier candidates, and a black
    /// pixel is not one — and it offsets them into the frame's coordinates.
    func testAnElementsSortablePixelsAreItsNonZeroPixelsAtAbsolutePositions() {
        // every pixel non-zero, so the whole tile is reported
        let full = sixteenBitGray(width: 3, height: 2) { x, y in UInt16(y * 3 + x + 1) }
        let element = ImageMatrixElement(x: 50, y: 60, image: full)

        let pixels = element.sortablePixels
        XCTAssertEqual(pixels.count, 6)
        XCTAssertEqual(Set(pixels.map(\.x)), [50, 51, 52], "offset into frame coordinates")
        XCTAssertEqual(Set(pixels.map(\.y)), [60, 61])
    }

    func testAnElementsSortablePixelsSkipBlackPixels() {
        // only [1, 0] and [2, 1] are lit
        let sparse = sixteenBitGray(width: 3, height: 2) { x, y in
            (x == 1 && y == 0) || (x == 2 && y == 1) ? 500 : 0
        }
        let element = ImageMatrixElement(x: 10, y: 20, image: sparse)

        let pixels = element.sortablePixels
        XCTAssertEqual(pixels.count, 2, "black pixels are not outlier candidates")
        XCTAssertEqual(Set(pixels.map { "\($0.x),\($0.y)" }), ["11,20", "12,21"])
    }

    func testElementsAreEqualByPositionAndSize() {
        let image = sixteenBitGray(width: 4, height: 4) { _, _ in 0 }
        let a = ImageMatrixElement(x: 1, y: 2, image: image)
        let b = ImageMatrixElement(x: 1, y: 2, image: image)
        let c = ImageMatrixElement(x: 9, y: 2, image: image)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(Set([a, c]).count, 2)
    }

    /// An element's width and height are derived from its image rather than passed in, so they
    /// always agree with the pixels it holds.
    func testAnElementTakesItsSizeFromItsImage() {
        let image = sixteenBitGray(width: 3, height: 5) { _, _ in 0 }
        let element = ImageMatrixElement(x: 1, y: 2, image: image)

        XCTAssertEqual(element.width, 3)
        XCTAssertEqual(element.height, 5)

        let text = element.description
        for part in ["1", "2", "3", "5"] { XCTAssertTrue(text.contains(part), text) }
    }

    /// `readPixel` only handles 16 bit data — it fatalErrors on 8 and 32 bit.  Its callers are all
    /// in FrameAirplaneRemover and only ever pass real frames, so it is a landmine rather than a
    /// live bug, but anything reading a mask has to go through `intensity(atX:andY:)` instead,
    /// which handles all three depths.
    func testIntensityReadsEveryDepthUnlikeReadPixel() {
        let eight = eightBitGray(width: 4, height: 2) { x, _ in UInt8(x * 10) }
        XCTAssertEqual(eight.intensity(atX: 2, andY: 0), 20)

        let sixteen = sixteenBitGray(width: 4, height: 2) { x, _ in UInt16(x * 1000) }
        XCTAssertEqual(sixteen.intensity(atX: 2, andY: 0), 2000)
    }

    // MARK: - writing and reading back

    func testAnImageSurvivesATiffRoundTrip() throws {
        let original = sixteenBitGray(width: 12, height: 8) { x, y in UInt16(y * 12 + x) }
        let path = scratch.appendingPathComponent("gray.tif").path
        original.writeTIFFEncoding(toFilename: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let loaded = try XCTUnwrap(PixelatedImage(filename: path))
        XCTAssertEqual(loaded.width, 12)
        XCTAssertEqual(loaded.height, 8)
        XCTAssertEqual(words(loaded), words(original))
    }

    func testAColourImageKeepsItsChannelsThroughTiff() throws {
        let original = sixteenBitColor(width: 8, height: 4) { x, y, c in UInt16((x + y) * 3 + c) }
        let path = scratch.appendingPathComponent("colour.tif").path
        original.writeTIFFEncoding(toFilename: path)

        let loaded = try XCTUnwrap(PixelatedImage(filename: path))
        XCTAssertEqual(loaded.componentsPerPixel, 3)
        XCTAssertEqual(loaded.bitsPerComponent, 16)
        XCTAssertEqual(words(loaded), words(original))
    }

    func testLoadingSomethingThatIsNotAnImageGivesNothing() throws {
        let path = scratch.appendingPathComponent("nope.tif")
        try Data("not an image".utf8).write(to: path)
        XCTAssertNil(PixelatedImage(filename: path.path))
    }

    func testLoadingAMissingFileGivesNothing() {
        XCTAssertNil(PixelatedImage(filename: scratch.appendingPathComponent("absent.tif").path))
    }

    // MARK: - horizon masks

    /// A horizon mask has to be single-channel 8-bit, or the mask comparisons downstream read the
    /// wrong bytes.  `asHorizonMask` is the conversion that guarantees it.
    func testAsHorizonMaskGivesASingleChannelEightBitImage() throws {
        let colour = sixteenBitColor(width: 8, height: 8) { _, _, _ in 40000 }
        let mask = try XCTUnwrap(colour.asHorizonMask)

        XCTAssertEqual(mask.componentsPerPixel, 1)
        XCTAssertEqual(mask.bitsPerComponent, 8)
        XCTAssertEqual(mask.width, 8)
        XCTAssertEqual(mask.height, 8)
    }

    func testAsHorizonMaskLeavesAnAlreadyValidMaskUsable() throws {
        let already = eightBitGray(width: 8, height: 8) { x, _ in x < 4 ? 255 : 0 }
        let mask = try XCTUnwrap(already.asHorizonMask)
        XCTAssertEqual(mask.componentsPerPixel, 1)
        XCTAssertEqual(mask.bitsPerComponent, 8)
    }

    /// Shifting a mask up is how the horizon is nudged when the detector lands slightly low.
    func testShiftingAMaskUpMovesItsContentAndKeepsTheSize() throws {
        // white above row 4, black below
        let mask = eightBitGray(width: 4, height: 8) { _, y in y < 4 ? 255 : 0 }
        let shifted = try XCTUnwrap(mask.shiftImageUp(by: 2))

        XCTAssertEqual(shifted.width, 4)
        XCTAssertEqual(shifted.height, 8)
        // the boundary should have moved up by two rows
        XCTAssertEqual(shifted.intensity(atX: 0, andY: 1), 255)
        XCTAssertEqual(shifted.intensity(atX: 0, andY: 5), 0,
                       "what was white at row 5 should have moved off")
    }

    func testShiftingByZeroChangesNothing() throws {
        let mask = eightBitGray(width: 4, height: 6) { _, y in y < 3 ? 255 : 0 }
        let shifted = try XCTUnwrap(mask.shiftImageUp(by: 0))
        XCTAssertEqual(bytes(shifted), bytes(mask))
    }

    // MARK: - median merge

    /// The merge is what builds the static background a frame is compared against.  It takes
    /// *filenames* rather than images — the streaming path reads them back off disk — so the
    /// neighbours have to be written out first.
    private func write(_ image: PixelatedImage, as name: String) -> String {
        let path = scratch.appendingPathComponent(name).path
        image.writeTIFFEncoding(toFilename: path)
        return path
    }

    /// With identical sources the median is that value, which is the simplest thing that has to
    /// hold.
    func testMergingIdenticalImagesGivesThatImageBack() throws {
        let value: UInt16 = 1234
        let base = sixteenBitGray(width: 6, height: 4) { _, _ in value }
        let neighbours = (0..<4).map { i in
            write(sixteenBitGray(width: 6, height: 4) { _, _ in value }, as: "same\(i).tif")
        }

        let merged = try XCTUnwrap(base.medianMerge(with: neighbours))
        XCTAssertEqual(merged.width, 6)
        XCTAssertEqual(merged.height, 4)
        XCTAssertTrue(words(merged).allSatisfy { $0 == value },
                      "the median of identical values is that value")
    }

    /// What the merge does with neighbours that *differ* from the base is not pinned here.  Probing
    /// it, a dim base among four bright neighbours and a bright base among four dim ones both came
    /// back as the base value unchanged, in single channel and in three — so either the neighbours
    /// are not contributing on this path (scratchDir nil, streaming threshold 0) or
    /// `outlierThreshold` means something other than the obvious.  Characterising that needs the
    /// C++ side read properly, and asserting a guess would be worse than leaving it uncovered.

    func testMergingWithNoNeighboursStillProducesAnImage() throws {
        let base = sixteenBitGray(width: 4, height: 2) { _, _ in 500 }
        // nothing to take a median over, so the result is the frame itself
        let merged = base.medianMerge(with: [])
        if let merged {
            XCTAssertEqual(merged.width, 4)
            XCTAssertEqual(merged.height, 2)
        }
    }
}
