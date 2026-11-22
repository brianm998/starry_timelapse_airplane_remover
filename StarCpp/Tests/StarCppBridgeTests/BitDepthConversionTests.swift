import XCTest
@testable import StarCppBridge

/// 8 <-> 16 bit conversions scale by 257 (255 <-> 65535), and a 16-bit frame's preview is
/// shown as it is unless it is one of the near-black debug types, which are stretched.
final class BitDepthConversionTests: XCTestCase {

    private func gray8(_ values: [UInt8], width: Int) -> MatWrapper {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: values.count)
        p.initialize(from: values, count: values.count)
        return MatWrapper(width: width, height: values.count / width,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: p, takeOwnership: true)
    }

    private func gray16(_ values: [UInt16], width: Int) -> MatWrapper {
        let p = UnsafeMutablePointer<UInt16>.allocate(capacity: values.count)
        p.initialize(from: values, count: values.count)
        return MatWrapper(width: width, height: values.count / width,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                          bytesPerRow: width * 2, data: p, takeOwnership: true)
    }

    private func pixels8(_ m: MatWrapper) -> [UInt8] {
        let n = m.rows * m.cols
        guard let base = m.dataPtr else { return [] }
        return (0..<n).map { i in
            base.load(fromByteOffset: (i / m.cols) * m.step + (i % m.cols) * m.channels, as: UInt8.self)
        }
    }

    private func pixels16(_ m: MatWrapper) -> [UInt16] {
        let n = m.rows * m.cols
        guard let base = m.dataPtr else { return [] }
        return (0..<n).map { i in
            base.load(fromByteOffset: (i / m.cols) * m.step + (i % m.cols) * 2 * m.channels, as: UInt16.self)
        }
    }

    private func jpegPixel(_ m: MatWrapper, stretched: Bool) throws -> UInt8 {
        let path = NSTemporaryDirectory() + "bitdepth-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(m.saveJpeg(quality: 95, filename: path, stretched: stretched))
        let back = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        return pixels8(back)[0]
    }

    func testRoundTrip() throws {
        let all = (0...255).map { UInt8($0) }
        let up = try XCTUnwrap(gray8(all, width: 16).ensure16Bits())
        XCTAssertEqual(pixels16(up), all.map { UInt16($0) * 257 })
        XCTAssertEqual(pixels16(up).last, 65535)
        XCTAssertEqual(pixels8(up.ensure8Bits()), all)
    }

    func testSixteenToEightRounds() {
        let m = gray16([65535, 128, 129, 0], width: 4)
        XCTAssertEqual(pixels8(m.ensure8Bits()), [255, 0, 1, 0])
    }

    func testPreviewIsNotStretched() throws {
        // A 16-bit frame at 20000 previews like its 8-bit twin, not stretched to white.
        let sixteen = gray16([UInt16](repeating: 20000, count: 64), width: 8)
        let twin = gray8([UInt8](repeating: UInt8((20000.0 / 257.0).rounded()), count: 64), width: 8)
        let a = try jpegPixel(sixteen, stretched: false)
        let b = try jpegPixel(twin, stretched: false)
        XCTAssertEqual(Int(a), Int(b), accuracy: 1)
        XCTAssertEqual(pixels8(sixteen.ensureEightBit(stretched: false))[0], 78)
    }

    func testDebugPreviewsStretch() throws {
        let values: [UInt16] = [0, 20000, 0, 20000]
        let m = gray16(values, width: 2)
        XCTAssertEqual(pixels8(m.ensureEightBit(stretched: true)), [0, 255, 0, 255])
        XCTAssertEqual(pixels8(m.ensureEightBit(stretched: false)), [0, 78, 0, 78])
        XCTAssertEqual(pixels8(m.ensureEightBit()), [0, 255, 0, 255], "default keeps old behaviour")
    }
}
