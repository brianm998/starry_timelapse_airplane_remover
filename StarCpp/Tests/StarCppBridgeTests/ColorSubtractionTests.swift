import XCTest
@testable import StarCppBridge

/// `pib_subtract_image_color`, the kernel behind the dirty clean methods: original minus
/// reference per channel, clipped at 0, in the original's own depth and channel count, and
/// (with a mask) exactly 0 on the dropped side.
final class ColorSubtractionTests: XCTestCase {

    private func make<T: FixedWidthInteger>(_ type: T.Type, width: Int, height: Int,
                                            pixels: [T]) -> MatWrapper {
        precondition(pixels.count == width * height * 3)
        let data = UnsafeMutablePointer<T>.allocate(capacity: pixels.count)
        defer { data.deallocate() }
        for (i, v) in pixels.enumerated() { data[i] = v }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: Int32(T.bitWidth), componentsPerPixel: 3),
                          bytesPerRow: width * 3 * MemoryLayout<T>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func makeMask(width: Int, height: Int, values: [UInt8]) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: values.count)
        defer { data.deallocate() }
        for (i, v) in values.enumerated() { data[i] = v }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func read<T: FixedWidthInteger>(_ type: T.Type, _ mat: MatWrapper) -> [T] {
        guard let base = mat.dataPtr else { return [] }
        var out: [T] = []
        for row in 0..<mat.rows {
            let rowPtr = base.advanced(by: row * mat.step).assumingMemoryBound(to: T.self)
            for i in 0..<(mat.cols * mat.channels) { out.append(rowPtr[i]) }
        }
        return out
    }

    func testColorSubtractionClipsAtZeroEightAndSixteenBit() throws {
        // two pixels: one brighter than the reference in blue and red, darker in green;
        // one entirely darker (all three channels clip to 0)
        let original8: [UInt8] = [200, 10, 90,   5, 5, 5]
        let reference8: [UInt8] = [50, 40, 30,   9, 9, 9]
        let out8 = try XCTUnwrap(PixelatedImageBridge.subtractImageColor(
            make(UInt8.self, width: 2, height: 1, pixels: reference8),
            fromImage: make(UInt8.self, width: 2, height: 1, pixels: original8)))
        XCTAssertEqual(out8.channels, 3)
        XCTAssertEqual(out8.bitsPerComponent, 8)
        XCTAssertEqual(read(UInt8.self, out8), [150, 0, 60,   0, 0, 0])

        let original16: [UInt16] = [60000, 1000, 30000,   100, 100, 100]
        let reference16: [UInt16] = [10000, 2000, 29999,   101, 99, 100]
        let out16 = try XCTUnwrap(PixelatedImageBridge.subtractImageColor(
            make(UInt16.self, width: 2, height: 1, pixels: reference16),
            fromImage: make(UInt16.self, width: 2, height: 1, pixels: original16)))
        XCTAssertEqual(out16.channels, 3)
        XCTAssertEqual(out16.bitsPerComponent, 16)
        XCTAssertEqual(read(UInt16.self, out16), [50000, 0, 1,   0, 1, 0])

        // an 8-bit reference against a 16-bit original is scaled up and the result stays 16-bit
        let mixed = try XCTUnwrap(PixelatedImageBridge.subtractImageColor(
            make(UInt8.self, width: 2, height: 1, pixels: [1, 0, 0,   0, 0, 0]),
            fromImage: make(UInt16.self, width: 2, height: 1, pixels: [1000, 0, 0,   7, 0, 0])))
        XCTAssertEqual(mixed.bitsPerComponent, 16)
        XCTAssertEqual(read(UInt16.self, mixed), [1000 - 257, 0, 0,   7, 0, 0])

        // with a mask, the dropped side is exactly 0 and the kept side is the subtraction
        let mask = makeMask(width: 2, height: 1, values: [255, 0])
        let original: [UInt8] = [200, 100, 50,   200, 100, 50]
        let keptSky = try XCTUnwrap(PixelatedImageBridge.subtractImageColor(
            make(UInt8.self, width: 2, height: 1, pixels: [0, 0, 0,   0, 0, 0]),
            fromImage: make(UInt8.self, width: 2, height: 1, pixels: original),
            mask: mask, keepMaskWhite: true))
        XCTAssertEqual(read(UInt8.self, keptSky), [200, 100, 50,   0, 0, 0])
        let keptGround = try XCTUnwrap(PixelatedImageBridge.subtractImageColor(
            make(UInt8.self, width: 2, height: 1, pixels: [0, 0, 0,   0, 0, 0]),
            fromImage: make(UInt8.self, width: 2, height: 1, pixels: original),
            mask: mask, keepMaskWhite: false))
        XCTAssertEqual(read(UInt8.self, keptGround), [0, 0, 0,   200, 100, 50])
    }
}
