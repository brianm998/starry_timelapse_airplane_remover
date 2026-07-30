import XCTest
@testable import StarCppBridge

/// `MatWrapper` is the seam between Swift and OpenCV: every image star loads, scales,
/// converts, tiles and writes goes through this handful of C entry points.  Nothing on this
/// side of the bridge had any coverage, so these tests are deliberately about the contract
/// rather than the arithmetic — that the depth conversions actually change depth, that a
/// clone is independent of its source, that split/combine is lossless, and that the
/// handles are released without leaking (the C layer keeps a live instance count, which
/// makes that checkable).
final class MatWrapperTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MatWrapperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - helpers

    /// Builds an owned Mat of the given geometry with a recognisable gradient in it.
    /// `takeOwnership: true` hands the malloc'd buffer to OpenCV, so there is no Swift-side
    /// lifetime to keep track of.
    private func makeEightBitGray(width: Int, height: Int) -> MatWrapper {
        let count = width * height
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        for i in 0..<count { data[i] = UInt8(i % 256) }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func makeSixteenBitColor(width: Int, height: Int) -> MatWrapper {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for i in 0..<count { data[i] = UInt16(truncatingIfNeeded: i * 257) }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                          bytesPerRow: width * 3 * 2,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    /// Reads one 8-bit single-channel pixel through `dataPtr` and `step`.
    ///
    /// `atDouble` cannot be used for this: it is `cv::Mat::at<double>`, which is only valid
    /// on a CV_64F matrix and returns 0 for anything else (see
    /// `testAtDoubleOnlyReadsDoubleMatrices`).  Going through the raw pointer is what the
    /// image code itself does.
    private func grayPixel(_ mat: MatWrapper, row: Int, col: Int) -> UInt8 {
        guard let base = mat.dataPtr else {
            XCTFail("mat has no data pointer")
            return 0
        }
        return base.load(fromByteOffset: row * mat.step + col, as: UInt8.self)
    }

    // MARK: - cv type mapping

    /// The type helper is the only place that knows how star's (bits, components) pairs map
    /// onto OpenCV's packed type codes, and a wrong answer here silently reinterprets pixel
    /// data.  Checking it through a real Mat rather than against hardcoded constants keeps
    /// the test honest about what the code actually means.
    func testEverySupportedDepthAndChannelCountMapsToAUsableType() {
        for (bits, components) in [(8, 1), (8, 3), (8, 4), (16, 1), (16, 3), (16, 4)] {
            let type = MatWrapper.cvType(forBitsPerComponent: Int32(bits),
                                         componentsPerPixel: Int32(components))
            XCTAssertNotEqual(type, -1, "\(bits) bit / \(components) channel is unsupported")

            let bytes = components * bits / 8
            let data = UnsafeMutableRawPointer.allocate(byteCount: bytes * 4, alignment: 8)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: bytes * 4)
            let mat = MatWrapper(width: 2, height: 2, cvType: type,
                                 bytesPerRow: bytes * 2, data: data, takeOwnership: true)

            XCTAssertEqual(mat.channels, components,
                           "\(bits)/\(components) came back with \(mat.channels) channels")
            XCTAssertEqual(mat.bitsPerComponent, bits,
                           "\(bits)/\(components) came back at \(mat.bitsPerComponent) bits")
            XCTAssertEqual(mat.bitsPerPixel, bits * components)
        }
    }

    func testAnUnsupportedCombinationIsRejectedRatherThanGuessed() {
        XCTAssertEqual(MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 2), -1)
        XCTAssertEqual(MatWrapper.cvType(forBitsPerComponent: 12, componentsPerPixel: 3), -1)
        XCTAssertEqual(MatWrapper.cvType(forBitsPerComponent: 32, componentsPerPixel: 3), -1)
    }

    func testDistinctDepthsGetDistinctTypeCodes() {
        let eight = MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 3)
        let sixteen = MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3)
        XCTAssertNotEqual(eight, sixteen)
    }

    // MARK: - geometry

    /// OpenCV is row-major and names its axes rows/cols, while star thinks in width/height.
    /// Getting the two transposed is the classic bug at this boundary.
    func testRowsAreHeightAndColsAreWidth() {
        let mat = makeEightBitGray(width: 7, height: 3)
        XCTAssertEqual(mat.cols, 7)
        XCTAssertEqual(mat.rows, 3)
        XCTAssertFalse(mat.isEmpty)
    }

    func testStepAndLengthDescribeTheSameBuffer() {
        let mat = makeSixteenBitColor(width: 5, height: 4)
        XCTAssertEqual(mat.step, 5 * 3 * 2, "one row is width * channels * bytes-per-component")
        XCTAssertEqual(mat.lengthInBytes, 5 * 4 * 3 * 2)
        XCTAssertNotNil(mat.dataPtr)
    }

    func testAMatBuiltFromABufferReportsItsChannelsAndDepth() {
        let mat = makeSixteenBitColor(width: 2, height: 2)
        XCTAssertEqual(mat.channels, 3)
        XCTAssertEqual(mat.bitsPerComponent, 16)
        XCTAssertTrue(mat.is16Bits)
        XCTAssertFalse(mat.is8Bits)
    }

    // MARK: - clone

    /// `clone` has to deep copy: the callers that use it are about to mutate one of the two.
    func testACloneHasTheSameShapeButItsOwnBuffer() {
        let original = makeEightBitGray(width: 6, height: 5)
        let copy = original.clone()

        XCTAssertEqual(copy.cols, original.cols)
        XCTAssertEqual(copy.rows, original.rows)
        XCTAssertEqual(copy.type, original.type)
        XCTAssertEqual(copy.lengthInBytes, original.lengthInBytes)
        XCTAssertNotEqual(copy.dataPtr, original.dataPtr,
                          "a clone that shares its buffer is not a clone")
    }

    func testACloneCarriesTheSamePixelValues() {
        let original = makeEightBitGray(width: 4, height: 4)
        let copy = original.clone()
        for row in 0..<4 {
            for col in 0..<4 {
                XCTAssertEqual(grayPixel(copy, row: row, col: col),
                               grayPixel(original, row: row, col: col),
                               "pixel [\(col), \(row)] differs in the clone")
            }
        }
    }

    /// `atDouble` is `cv::Mat::at<double>`, so it is only meaningful on a CV_64F matrix —
    /// which in practice means the 3x3 homographies.  On an image it does not reinterpret
    /// the bytes, it fails the OpenCV type assertion and the C layer swallows it into a 0.
    /// A caller reaching for it to read a pixel gets silent zeros, so it is worth a test
    /// saying so out loud.
    func testAtDoubleOnlyReadsDoubleMatrices() {
        let homography = MatWrapper.fromHomographyValues([9, 8, 7, 6, 5, 4, 3, 2, 1])
        XCTAssertEqual(homography.atDouble(row: 0, col: 0), 9)

        let image = makeEightBitGray(width: 4, height: 4)
        XCTAssertNotEqual(grayPixel(image, row: 1, col: 1), 0, "the fixture should be non-zero here")
        XCTAssertEqual(image.atDouble(row: 1, col: 1), 0,
                       "atDouble on an 8 bit image returns 0 rather than the pixel")
    }

    // MARK: - depth conversion

    func testEnsure16BitsPromotesAnEightBitMat() {
        let eight = makeEightBitGray(width: 4, height: 4)
        XCTAssertTrue(eight.is8Bits)

        let sixteen = eight.ensure16Bits()
        XCTAssertTrue(sixteen.is16Bits)
        XCTAssertFalse(sixteen.is8Bits)
        XCTAssertEqual(sixteen.cols, 4)
        XCTAssertEqual(sixteen.rows, 4)
        XCTAssertEqual(sixteen.channels, 1)
    }

    func testEnsure8BitsDemotesASixteenBitMat() {
        let sixteen = makeSixteenBitColor(width: 4, height: 4)
        let eight = sixteen.ensure8Bits()
        XCTAssertTrue(eight.is8Bits)
        XCTAssertEqual(eight.channels, 3, "demoting depth must not drop channels")
        XCTAssertEqual(eight.cols, 4)
        XCTAssertEqual(eight.rows, 4)
    }

    func testEnsuringADepthAMatAlreadyHasIsANoOpInShape() {
        let eight = makeEightBitGray(width: 3, height: 3)
        let again = eight.ensure8Bits()
        XCTAssertTrue(again.is8Bits)
        XCTAssertEqual(again.cols, 3)
        XCTAssertEqual(again.rows, 3)
    }

    func testARoundTripThroughSixteenBitsAndBackKeepsTheGeometry() {
        let original = makeEightBitGray(width: 5, height: 6)
        let back = original.ensure16Bits().ensure8Bits()
        XCTAssertTrue(back.is8Bits)
        XCTAssertEqual(back.cols, 5)
        XCTAssertEqual(back.rows, 6)
    }

    /// Horizon masks must be single-channel 8-bit or the mask comparisons downstream read
    /// the wrong bytes.  This is the one conversion with a documented hard requirement.
    func testEnsureGray8UCollapsesColourToOneEightBitChannel() {
        let colour = makeSixteenBitColor(width: 4, height: 4)
        let gray = colour.ensureGray8U()
        XCTAssertEqual(gray.channels, 1)
        XCTAssertEqual(gray.bitsPerComponent, 8)
        XCTAssertTrue(gray.is8Bits)
        XCTAssertEqual(gray.cols, 4)
        XCTAssertEqual(gray.rows, 4)
    }

    func testEnsureGray8UOnAnAlreadyGrayMatKeepsIt() {
        let gray = makeEightBitGray(width: 4, height: 4).ensureGray8U()
        XCTAssertEqual(gray.channels, 1)
        XCTAssertEqual(gray.bitsPerComponent, 8)
    }

    // MARK: - scaling

    func testDownScaleProducesTheRequestedSize() throws {
        let mat = makeEightBitGray(width: 40, height: 20)
        let small = try XCTUnwrap(mat.downScale(to: 10, height: 5))
        XCTAssertEqual(small.cols, 10)
        XCTAssertEqual(small.rows, 5)
        XCTAssertEqual(small.channels, mat.channels)
    }

    func testUpScaleProducesTheRequestedSize() throws {
        let mat = makeEightBitGray(width: 10, height: 5)
        let big = try XCTUnwrap(mat.upScale(to: 40, height: 20))
        XCTAssertEqual(big.cols, 40)
        XCTAssertEqual(big.rows, 20)
        XCTAssertEqual(big.channels, mat.channels)
    }

    /// The keypoint downscale divisor path scales by an integer factor and then works in
    /// the reduced frame, so the sizes have to come out exactly.
    func testScalingByADivisorGivesExactDimensions() throws {
        let mat = makeEightBitGray(width: 64, height: 32)
        for divisor in [2, 4, 8] {
            let scaled = try XCTUnwrap(mat.downScale(to: UInt(64 / divisor), height: UInt(32 / divisor)))
            XCTAssertEqual(scaled.cols, 64 / divisor)
            XCTAssertEqual(scaled.rows, 32 / divisor)
        }
    }

    // MARK: - crop and pad

    func testBottomCropRemovesRowsFromTheTop() throws {
        // despite the name, the C implementation takes a roi starting at row n
        let mat = makeEightBitGray(width: 8, height: 10)
        let cropped = try XCTUnwrap(mat.bottomCrop(4))
        XCTAssertEqual(cropped.rows, 6)
        XCTAssertEqual(cropped.cols, 8)
    }

    func testCroppingEverythingAwayGivesAnEmptyMatRatherThanCrashing() throws {
        let mat = makeEightBitGray(width: 8, height: 10)
        let cropped = try XCTUnwrap(mat.bottomCrop(10))
        XCTAssertTrue(cropped.isEmpty)
    }

    func testAddingWhiteRowsOnTopGrowsHeightAndFillsWithWhite() {
        let mat = makeEightBitGray(width: 8, height: 4)
        let padded = mat.addWhiteRows(onTop: 3)
        XCTAssertEqual(padded.rows, 7)
        XCTAssertEqual(padded.cols, 8)
        for col in 0..<8 {
            XCTAssertEqual(grayPixel(padded, row: 0, col: col), 255, "the new top row is not white")
            XCTAssertEqual(grayPixel(padded, row: 2, col: col), 255, "the last new row is not white")
        }
    }

    /// The original image has to survive underneath the padding, shifted down by exactly the
    /// number of rows added.
    func testAddingWhiteRowsShiftsTheOriginalDownwards() {
        let mat = makeEightBitGray(width: 8, height: 4)
        let padded = mat.addWhiteRows(onTop: 3)
        for row in 0..<4 {
            for col in 0..<8 {
                XCTAssertEqual(grayPixel(padded, row: row + 3, col: col),
                               grayPixel(mat, row: row, col: col),
                               "original pixel [\(col), \(row)] is not at row \(row + 3)")
            }
        }
    }

    func testAddingZeroWhiteRowsLeavesTheHeightAlone() {
        let mat = makeEightBitGray(width: 8, height: 4)
        XCTAssertEqual(mat.addWhiteRows(onTop: 0).rows, 4)
    }

    // MARK: - homography

    /// Homographies are cached to disk and read back, so the 3x3 <-> flat-array conversion
    /// has to be exact and in a stable order.
    func testAHomographyRoundTripsThroughItsNineValues() throws {
        let values: [Double] = [1.5, 0.25, -3, 0.125, 2, 7, 0.001, -0.002, 1]
        let mat = MatWrapper.fromHomographyValues(values)
        let back = try XCTUnwrap(mat.homographyValues)
        XCTAssertEqual(back, values)
    }

    func testTheConvenienceInitializerAgreesWithTheFactory() throws {
        let values: [Double] = [2, 0, 5, 0, 2, 5, 0, 0, 1]
        let viaInit = try XCTUnwrap(MatWrapper(homographyValues: values).homographyValues)
        let viaFactory = try XCTUnwrap(MatWrapper.fromHomographyValues(values).homographyValues)
        XCTAssertEqual(viaInit, viaFactory)
    }

    func testHomographyValuesAreRowMajor() throws {
        let values: [Double] = [0, 1, 2, 3, 4, 5, 6, 7, 8]
        let mat = MatWrapper.fromHomographyValues(values)
        XCTAssertEqual(mat.rows, 3)
        XCTAssertEqual(mat.cols, 3)
        // row 1 holds 3, 4, 5 if the flat array was laid out row by row
        XCTAssertEqual(mat.atDouble(row: 1, col: 0), 3)
        XCTAssertEqual(mat.atDouble(row: 1, col: 2), 5)
    }

    /// Asking a plain image for a homography must fail rather than reinterpret its pixels.
    func testAnImageMatHasNoHomographyValues() {
        XCTAssertNil(makeEightBitGray(width: 3, height: 3).homographyValues)
    }

    // MARK: - split / combine

    /// Tiling is how the classifier and the horizon detector see an image.  The tiles have
    /// to cover it, and recombining them has to give the geometry back.
    func testSplittingWithoutOverlapTilesTheWholeImage() {
        let mat = makeEightBitGray(width: 64, height: 32)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0)

        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(Set(tiles.map { $0.x }), [0, 32])
        for tile in tiles {
            XCTAssertEqual(tile.y, 0)
            XCTAssertEqual(tile.width, 32)
            XCTAssertEqual(tile.height, 32)
            XCTAssertEqual(tile.image.cols, 32)
            XCTAssertEqual(tile.image.rows, 32)
        }
    }

    func testTilesAreRowMajor() {
        let mat = makeEightBitGray(width: 64, height: 64)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0)
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles.map { ($0.x, $0.y) }.map { "\($0.0),\($0.1)" },
                       ["0,0", "32,0", "0,32", "32,32"],
                       "tiles should come back y-outer, x-inner")
    }

    /// `overlapPercent` is a fraction, not a percentage: the stride is
    /// `tileSize * (1 - overlapPercent)`, so 0.5 halves it.
    func testOverlappingTilesStepByLessThanATileWidth() {
        let mat = makeEightBitGray(width: 96, height: 32)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0.5)

        let xs = Set(tiles.map { $0.x }).sorted()
        XCTAssertEqual(xs, [0, 16, 32, 48, 64, 80],
                       "50% overlap on a 32 wide tile is a stride of 16")

        // 32 rows with a stride of 16 gives two rows of tiles, the second one a half tile
        XCTAssertEqual(Set(tiles.map { $0.y }).sorted(), [0, 16])
        XCTAssertEqual(tiles.count, 12)
    }

    func testNoOverlapMeansAStrideOfAWholeTile() {
        let mat = makeEightBitGray(width: 96, height: 32)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0)
        XCTAssertEqual(Set(tiles.map { $0.x }).sorted(), [0, 32, 64])
        XCTAssertEqual(Set(tiles.map { $0.y }).sorted(), [0])
    }

    /// A full overlap would mean a zero stride and an infinite loop, so it is refused.
    func testACompleteOverlapProducesNoTilesRatherThanHanging() {
        let mat = makeEightBitGray(width: 64, height: 64)
        XCTAssertTrue(mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 1.0).isEmpty)
    }

    /// Partial tiles at the right and bottom edges are reported at their real size, not the
    /// requested one — callers that trust `width`/`height` would otherwise read past the end.
    func testEdgeTilesReportTheirTruncatedSize() {
        let mat = makeEightBitGray(width: 40, height: 20)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0)

        XCTAssertEqual(tiles.count, 2)
        for tile in tiles {
            XCTAssertEqual(tile.image.cols, tile.width, "reported width disagrees with the tile")
            XCTAssertEqual(tile.image.rows, tile.height)
            XCTAssertLessThanOrEqual(tile.x + tile.width, 40)
            XCTAssertLessThanOrEqual(tile.y + tile.height, 20)
        }
        XCTAssertEqual(tiles.last?.width, 8, "the right hand tile only has 8 columns left")
        XCTAssertEqual(tiles.last?.height, 20)
    }

    func testCombiningTilesRebuildsTheOriginalGeometry() throws {
        let mat = makeEightBitGray(width: 64, height: 32)
        let tiles = mat.split(tileWidth: 32, tileHeight: 32, overlapPercent: 0)
        let rebuilt = try XCTUnwrap(MatWrapper.combine(from: tiles))

        XCTAssertEqual(rebuilt.cols, mat.cols)
        XCTAssertEqual(rebuilt.rows, mat.rows)
        XCTAssertEqual(rebuilt.type, mat.type)
    }

    func testCombiningTilesRebuildsThePixelValues() throws {
        let mat = makeEightBitGray(width: 32, height: 32)
        let tiles = mat.split(tileWidth: 16, tileHeight: 16, overlapPercent: 0)
        let rebuilt = try XCTUnwrap(MatWrapper.combine(from: tiles))

        for row in 0..<32 {
            for col in 0..<32 {
                XCTAssertEqual(grayPixel(rebuilt, row: row, col: col),
                               grayPixel(mat, row: row, col: col),
                               "pixel [\(col), \(row)] did not survive split/combine")
            }
        }
    }

    func testCombiningNothingGivesNothing() {
        XCTAssertNil(MatWrapper.combine(from: []))
    }

    /// A tile size larger than the image should still produce one tile covering it, rather
    /// than none.
    func testATileBiggerThanTheImageStillYieldsOneTile() {
        let mat = makeEightBitGray(width: 20, height: 10)
        let tiles = mat.split(tileWidth: 64, tileHeight: 64, overlapPercent: 0)
        XCTAssertEqual(tiles.count, 1)
        XCTAssertEqual(tiles.first?.width, 20)
        XCTAssertEqual(tiles.first?.height, 10)
    }

    // MARK: - file round trip

    /// `write(to:)` picks its format from the extension, and star relies on that for both
    /// TIFF output and PNG masks.  A load has to give back what was written.
    func testAGrayMatSurvivesATiffRoundTrip() throws {
        let original = makeEightBitGray(width: 16, height: 8)
        let path = scratch.appendingPathComponent("gray.tif").path
        original.write(to: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "nothing was written")
        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(loaded.cols, 16)
        XCTAssertEqual(loaded.rows, 8)
        for row in 0..<8 {
            for col in 0..<16 {
                XCTAssertEqual(grayPixel(loaded, row: row, col: col),
                               grayPixel(original, row: row, col: col),
                               "pixel [\(col), \(row)] changed on the way through tiff")
            }
        }
    }

    func testASixteenBitMatStaysSixteenBitThroughTiff() throws {
        let original = makeSixteenBitColor(width: 8, height: 8)
        let path = scratch.appendingPathComponent("colour.tif").path
        original.write(to: path)

        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertTrue(loaded.is16Bits, "tiff round trip must not quietly drop to 8 bits")
        XCTAssertEqual(loaded.channels, 3)
        XCTAssertEqual(loaded.cols, 8)
        XCTAssertEqual(loaded.rows, 8)
    }

    func testAPngRoundTripIsLossless() throws {
        let original = makeEightBitGray(width: 12, height: 6)
        let path = scratch.appendingPathComponent("mask.png").path
        original.write(to: path)

        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        for row in 0..<6 {
            for col in 0..<12 {
                XCTAssertEqual(grayPixel(loaded, row: row, col: col),
                               grayPixel(original, row: row, col: col),
                               "pixel [\(col), \(row)] changed on the way through png")
            }
        }
    }

    func testSaveJpegWritesAFile() throws {
        let original = makeEightBitGray(width: 16, height: 16)
        let path = scratch.appendingPathComponent("preview.jpg").path
        original.saveJpeg(quality: 90, filename: path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(loaded.cols, 16)
        XCTAssertEqual(loaded.rows, 16)
    }

    func testLoadingSomethingThatIsNotAnImageReturnsNil() throws {
        let path = scratch.appendingPathComponent("not-an-image.tif")
        try Data("this is not a tiff".utf8).write(to: path)
        XCTAssertNil(MatWrapper.load(fromFilename: path.path))
    }

    func testLoadingAMissingFileReturnsNil() {
        XCTAssertNil(MatWrapper.load(fromFilename: scratch.appendingPathComponent("nope.tif").path))
    }

    // MARK: - lifetime

    /// The C layer counts live instances, which is the only way to notice from Swift that
    /// `deinit` is releasing its ref.  A leak here grows without bound across a sequence.
    func testHandlesAreReleasedWhenTheirWrappersGoAway() {
        let before = MatWrapper.totalInstances
        do {
            let mat = makeEightBitGray(width: 32, height: 32)
            _ = mat.clone()
            _ = mat.ensure16Bits()
            XCTAssertGreaterThan(MatWrapper.totalInstances, before)
        }
        XCTAssertEqual(MatWrapper.totalInstances, before,
                       "MatWrapper handles were not released")
    }

    func testSplitTilesAreReleasedToo() {
        let before = MatWrapper.totalInstances
        do {
            let mat = makeEightBitGray(width: 64, height: 64)
            let tiles = mat.split(tileWidth: 16, tileHeight: 16, overlapPercent: 0)
            XCTAssertEqual(tiles.count, 16)
        }
        XCTAssertEqual(MatWrapper.totalInstances, before, "split tiles leaked their handles")
    }
}
