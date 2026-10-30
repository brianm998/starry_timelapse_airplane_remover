import XCTest
@testable import StarCppBridge

/// Which TIFF compression a frame is written with.
///
/// `mat_wrapper_write_to` used to leave it to OpenCV, which means LZW with a horizontal predictor
/// whatever the picture.  On night-sky noise that is a net loss on both counts: a 24 MP merged frame
/// came out at 148 MB against 144 MB uncompressed, and the encode was 15% of the merge phase's CPU.
/// It now encodes a few sample rows the way the file would be and writes the frame uncompressed unless
/// that takes a tenth or more off — so noise is written plain, and smooth frames and 8-bit masks, which
/// compress several-fold, keep LZW.  Pixels are the same either way; what these pin is the choice, and
/// that nothing is lost in the file that is written.
final class TiffCompressionTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TiffCompressionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        unsetenv("STAR_TIFF_COMPRESSION")
    }

    override func tearDownWithError() throws {
        unsetenv("STAR_TIFF_COMPRESSION")
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// The Compression tag of the first IFD of a TIFF: 1 is none, 5 is LZW.
    private func compressionTag(_ path: String) throws -> Int {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, 16)
        let little = data[0] == 0x49
        func u16(_ o: Int) -> Int { little ? Int(data[o]) | Int(data[o + 1]) << 8 : Int(data[o]) << 8 | Int(data[o + 1]) }
        func u32(_ o: Int) -> Int { little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
        let ifd = u32(4)
        for i in 0..<u16(ifd) where u16(ifd + 2 + 12 * i) == 259 {
            return u16(ifd + 2 + 12 * i + 8)
        }
        XCTFail("no Compression tag")
        return 0
    }

    private func makeMat(width: Int, height: Int, channels: Int, bits: Int,
                         _ sample: (Int, Int, Int) -> UInt16) -> MatWrapper {
        let bytesPer = bits / 8
        let rowBytes = width * channels * bytesPer
        let data = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * height, alignment: 16)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    let v = sample(x, y, c)
                    let o = y * rowBytes + (x * channels + c) * bytesPer
                    if bits == 16 { data.storeBytes(of: v, toByteOffset: o, as: UInt16.self) }
                    else { data.storeBytes(of: UInt8(truncatingIfNeeded: v), toByteOffset: o, as: UInt8.self) }
                }
            }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: Int32(bits), componentsPerPixel: Int32(channels)),
                          bytesPerRow: rowBytes, data: data, takeOwnership: true)
    }

    private func bytes(of mat: MatWrapper) -> [UInt8] {
        let rowBytes = mat.cols * mat.channels * (mat.bitsPerComponent / 8)
        return (0..<mat.rows).flatMap { y -> [UInt8] in
            let row = mat.dataPtr!.advanced(by: y * mat.step).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: row, count: rowBytes))
        }
    }

    /// Sensor-like noise in 16 bits: LZW cannot take anything off.
    private func noise(_ x: Int, _ y: Int, _ c: Int) -> UInt16 {
        let a: UInt64 = UInt64(x) &* 0x9E37_79B9_7F4A_7C15
        let b: UInt64 = UInt64(y) &* 0xBF58_476D_1CE4_E5B9
        let d: UInt64 = UInt64(c) &* 0x94D0_49BB_1331_11EB
        var h: UInt64 = a ^ b ^ d
        h ^= h >> 31
        h = h &* 0xD6E8_FEB8_6659_FD93
        h ^= h >> 29
        let v: Int = 20000 + Int(h % 4000)
        return UInt16(truncatingIfNeeded: v)
    }

    func testANoisyFrameIsWrittenUncompressedAndComesBackExactly() throws {
        let mat = makeMat(width: 2400, height: 1800, channels: 3, bits: 16, noise)    // 26 MB
        let path = scratch.appendingPathComponent("noise.tiff").path
        XCTAssertTrue(mat.write(to: path))
        XCTAssertEqual(try compressionTag(path), 1, "LZW cannot compress noise; it should not be asked to")
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
        // the pixels plus a header and the strip tables (one strip a row: ~11 KB here), not LZW's expansion
        XCTAssertLessThan(size, 2400 * 1800 * 6 + 65536, "no larger than the pixels and the file's tables")
        let back = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(bytes(of: back), bytes(of: mat))
    }

    func testASmoothFrameKeepsLZWAndComesBackExactly() throws {
        let mat = makeMat(width: 2400, height: 1800, channels: 3, bits: 16) { x, y, c in
            let v: Int = 3000 + x * 5 + y * 3 + c * 100     // a gradient: compresses well
            return UInt16(v)
        }
        let path = scratch.appendingPathComponent("smooth.tiff").path
        XCTAssertTrue(mat.write(to: path))
        XCTAssertEqual(try compressionTag(path), 5, "a frame LZW takes a lot off keeps it")
        let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int
        XCTAssertLessThan(size, 2400 * 1800 * 6 / 2)
        let back = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(bytes(of: back), bytes(of: mat))
    }

    /// The 8-bit masks are the other big compressible thing star writes.
    func testALargeMaskKeepsLZW() throws {
        let mat = makeMat(width: 4000, height: 2500, channels: 1, bits: 8) { x, y, _ in
            let edge: Int = 1500 + Int(30 * sin(Double(x) / 90))
            return y < edge ? 255 : 0
        }
        let path = scratch.appendingPathComponent("mask.tiff").path
        XCTAssertTrue(mat.write(to: path))
        XCTAssertEqual(try compressionTag(path), 5)
    }

    /// Small frames are not what this is for: written as before, whatever they hold.
    func testASmallNoisyFrameIsWrittenAsBefore() throws {
        let mat = makeMat(width: 64, height: 48, channels: 3, bits: 16, noise)
        let path = scratch.appendingPathComponent("small.tiff").path
        XCTAssertTrue(mat.write(to: path))
        XCTAssertEqual(try compressionTag(path), 5)
    }

    func testTheEnvironmentOverridesTheRule() throws {
        let noisy = makeMat(width: 2400, height: 1800, channels: 3, bits: 16, noise)
        let smooth = makeMat(width: 2400, height: 1800, channels: 3, bits: 16) { x, y, c in
            let v: Int = 3000 + x + y + c
            return UInt16(v)
        }

        setenv("STAR_TIFF_COMPRESSION", "lzw", 1)
        let forcedLZW = scratch.appendingPathComponent("forced-lzw.tiff").path
        XCTAssertTrue(noisy.write(to: forcedLZW))
        XCTAssertEqual(try compressionTag(forcedLZW), 5, "STAR_TIFF_COMPRESSION=lzw is what was written before")

        setenv("STAR_TIFF_COMPRESSION", "none", 1)
        let forcedNone = scratch.appendingPathComponent("forced-none.tiff").path
        XCTAssertTrue(smooth.write(to: forcedNone))
        XCTAssertEqual(try compressionTag(forcedNone), 1)
        let back = try XCTUnwrap(MatWrapper.load(fromFilename: forcedNone))
        XCTAssertEqual(bytes(of: back), bytes(of: smooth))
    }
}
