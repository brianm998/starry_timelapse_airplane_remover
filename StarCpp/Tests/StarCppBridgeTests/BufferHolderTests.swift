import XCTest
@testable import StarCppBridge

/// `BufferHolder` owns the raw pixel bytes that star assembles a processed frame into before
/// handing it to OpenCV.  It is a thin wrapper, but it is the one place a wrong length or a
/// wrong element size corrupts an entire output image, so the arithmetic is worth pinning.
final class BufferHolderTests: XCTestCase {

    /// Reads one 8-bit single-channel pixel out of a Mat through its raw pointer.
    /// `MatWrapper.atDouble` is only valid on CV_64F matrices and quietly returns 0 for an
    /// image, so it cannot be used here.
    private func grayPixel(_ mat: MatWrapper, row: Int, col: Int) -> UInt8 {
        guard let base = mat.dataPtr else {
            XCTFail("mat has no data pointer")
            return 0
        }
        return base.load(fromByteOffset: row * mat.step + col, as: UInt8.self)
    }

    // MARK: - allocation

    func testLengthIsWidthTimesHeightTimesComponentsTimesBytesPerComponent() {
        let eightBit = BufferHolder(width: 10, height: 4, components: 3, bitsPerComponent: 8)
        XCTAssertEqual(eightBit.length, 10 * 4 * 3 * 1)

        let sixteenBit = BufferHolder(width: 10, height: 4, components: 3, bitsPerComponent: 16)
        XCTAssertEqual(sixteenBit.length, 10 * 4 * 3 * 2)

        let thirtyTwoBit = BufferHolder(width: 10, height: 4, components: 1, bitsPerComponent: 32)
        XCTAssertEqual(thirtyTwoBit.length, 10 * 4 * 1 * 4)
    }

    func testTheGeometryItWasAskedForIsWhatItReportsBack() {
        let holder = BufferHolder(width: 33, height: 17, components: 4, bitsPerComponent: 16)
        XCTAssertEqual(holder.width, 33)
        XCTAssertEqual(holder.height, 17)
        XCTAssertEqual(holder.components, 4)
        XCTAssertEqual(holder.bitsPerComponent, 16)
    }

    /// A fresh buffer is documented as zero filled, and the frame assembly relies on that:
    /// it writes only the pixels it changes and expects the rest to be black.
    func testAFreshBufferIsZeroFilled() throws {
        let holder = BufferHolder(width: 8, height: 8, components: 3, bitsPerComponent: 8)
        let bytes = try XCTUnwrap(holder.asUInt8)
        for i in 0..<Int(holder.length) {
            XCTAssertEqual(bytes[i], 0, "byte \(i) of a fresh buffer was not zero")
        }
    }

    func testTheBufferPointerIsNonNilForANonEmptyBuffer() {
        let holder = BufferHolder(width: 4, height: 4, components: 1, bitsPerComponent: 8)
        XCTAssertNotNil(holder.buffer)
    }

    // MARK: - typed access

    /// The three typed accessors are the same pointer reinterpreted, so a value written
    /// through one must be visible through the others.  That is what makes the 16-bit
    /// pixel writes land where the 8-bit length arithmetic says they should.
    func testTypedAccessorsAliasTheSameBytes() throws {
        let holder = BufferHolder(width: 4, height: 1, components: 1, bitsPerComponent: 16)
        let words = try XCTUnwrap(holder.asUInt16)
        words[0] = 0x1234

        let bytes = try XCTUnwrap(holder.asUInt8)
        // little endian on every platform star builds for
        XCTAssertEqual(bytes[0], 0x34)
        XCTAssertEqual(bytes[1], 0x12)
    }

    func testSixteenBitWritesSpanTheWholeBuffer() throws {
        let holder = BufferHolder(width: 4, height: 2, components: 1, bitsPerComponent: 16)
        let words = try XCTUnwrap(holder.asUInt16)
        let wordCount = Int(holder.length) / 2
        XCTAssertEqual(wordCount, 8)

        for i in 0..<wordCount { words[i] = UInt16(0xFFFF - i) }
        for i in 0..<wordCount { XCTAssertEqual(words[i], UInt16(0xFFFF - i)) }
    }

    // MARK: - copying an existing buffer

    func testCopyingABufferReproducesItsContents() throws {
        var source: [UInt8] = (0..<48).map { UInt8($0) }
        let holder = source.withUnsafeBytes { raw in
            BufferHolder(copyingBuffer: raw.baseAddress!,
                         width: 4, height: 4, components: 3, bitsPerComponent: 8)
        }

        XCTAssertEqual(holder.length, 48)
        let bytes = try XCTUnwrap(holder.asUInt8)
        for i in 0..<48 { XCTAssertEqual(bytes[i], source[i]) }

        // and it is a copy, not an alias — mutating the source must not reach the holder
        source[0] = 0xFF
        XCTAssertEqual(bytes[0], 0)
    }

    // MARK: - conversion to a Mat

    func testConvertingToAMatKeepsTheGeometry() {
        let holder = BufferHolder(width: 12, height: 5, components: 3, bitsPerComponent: 8)
        let mat = holder.toMat()
        XCTAssertEqual(mat.cols, 12)
        XCTAssertEqual(mat.rows, 5)
        XCTAssertEqual(mat.channels, 3)
        XCTAssertEqual(mat.bitsPerComponent, 8)
    }

    func testConvertingASixteenBitBufferGivesASixteenBitMat() {
        let mat = BufferHolder(width: 8, height: 8, components: 3, bitsPerComponent: 16).toMat()
        XCTAssertTrue(mat.is16Bits)
        XCTAssertEqual(mat.channels, 3)
    }

    /// The C side clones on conversion, so the Mat must keep working after the holder that
    /// produced it has been released.  Getting this wrong is a use-after-free rather than a
    /// wrong number, so it is worth an explicit test.
    func testAMatOutlivesTheBufferHolderItCameFrom() throws {
        var mat: MatWrapper?
        do {
            let holder = BufferHolder(width: 8, height: 4, components: 1, bitsPerComponent: 8)
            let bytes = try XCTUnwrap(holder.asUInt8)
            for i in 0..<Int(holder.length) { bytes[i] = 42 }
            mat = holder.toMat()
        }
        let survivor = try XCTUnwrap(mat)
        XCTAssertEqual(survivor.cols, 8)
        XCTAssertEqual(survivor.rows, 4)
        XCTAssertEqual(grayPixel(survivor, row: 0, col: 0), 42)
        XCTAssertEqual(grayPixel(survivor, row: 3, col: 7), 42)
    }

    func testPixelValuesWrittenIntoTheBufferShowUpInTheMat() throws {
        let holder = BufferHolder(width: 4, height: 2, components: 1, bitsPerComponent: 8)
        let bytes = try XCTUnwrap(holder.asUInt8)
        // row major: row 1, column 2 is byte 1*4 + 2
        bytes[1 * 4 + 2] = 200

        let mat = holder.toMat()
        XCTAssertEqual(grayPixel(mat, row: 1, col: 2), 200)
        XCTAssertEqual(grayPixel(mat, row: 0, col: 0), 0)
    }

    // MARK: - lifetime

    func testConvertingToAMatDoesNotLeakMatHandles() {
        let before = MatWrapper.totalInstances
        do {
            let holder = BufferHolder(width: 16, height: 16, components: 3, bitsPerComponent: 8)
            _ = holder.toMat()
        }
        XCTAssertEqual(MatWrapper.totalInstances, before)
    }
}
