import XCTest
import StarCppBridge
@testable import StarCore

/// The array-based `FullFrameBlobber` against the actor-based one it replaced
/// (`LegacyFullFrameBlobber`, kept in this target verbatim): same blobs, same ids, same pixels,
/// on synthetic fields built to exercise the awkward parts and on real subtraction images.
final class FullFrameBlobberIdentityTests: XCTestCase {

    private func args(minIntensity: UInt16 = 6000, startSize: Int = 10, endSize: Int = 100,
                      startContrast: Double = 30, endContrast: Double = 5) -> BlobFinder.Args {
        BlobFinder.Args(minPixelIntensity: minIntensity, startContrastSize: startSize,
                        endContrastSize: endSize, startMinContrast: startContrast,
                        endMinContrast: endContrast)
    }

    private func dummyImage() -> PixelatedImage {
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: 4)
        data.initialize(repeating: 0, count: 4)
        let mat = MatWrapper(width: 2, height: 2,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                             bytesPerRow: 4, data: UnsafeMutableRawPointer(data), takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    /// (id, sorted pixel list) for every blob, in id order.
    private func fingerprint(_ blobs: [Blob]) async -> [String] {
        var out: [(Int32, String)] = []
        for blob in blobs {
            let pixels = await blob.getPixels().sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            out.append((blob.id, pixels.map { "\($0.x),\($0.y),\($0.uInt32Value)" }.joined(separator: ";")))
        }
        return out.sorted { $0.0 < $1.0 }.map { "\($0.0): \($0.1)" }
    }

    private func compare(_ subtraction: [UInt16], width: Int, height: Int,
                         args: BlobFinder.Args,
                         neighborType: FullFrameBlobber.NeighborType = .eight,
                         within bounds: BoundingBox? = nil,
                         config: Config = Config(),
                         startingBlobID: UInt16 = 1,
                         _ what: String,
                         file: StaticString = #filePath, line: UInt = #line) async -> Int
    {
        let legacy = await LegacyFullFrameBlobber(
          config: config, args: args, imageWidth: width, imageHeight: height, within: bounds,
          subtractionPixelData: subtraction, originalImage: dummyImage(), frameIndex: 0,
          neighborType: legacyType(neighborType), startingBlobID: startingBlobID)
        legacy.sortPixels()
        await legacy.process()

        let rewritten = await FullFrameBlobber(
          config: config, args: args, imageWidth: width, imageHeight: height, within: bounds,
          subtractionPixelData: subtraction, frameIndex: 0,
          neighborType: neighborType, startingBlobID: startingBlobID)
        rewritten.sortPixels()
        await rewritten.process()

        // the sort itself
        XCTAssertEqual(legacy.sortedPixels.map { "\($0.x),\($0.y)" },
                       rewritten.sortedPixels.map { "\($0.x),\($0.y)" },
                       "\(what): sorted pixel order differs", file: file, line: line)

        let a = await fingerprint(legacy.blobs), b = await fingerprint(rewritten.blobs)
        XCTAssertEqual(a.count, b.count, "\(what): blob count", file: file, line: line)
        XCTAssertEqual(a, b, "\(what): blobs differ", file: file, line: line)
        // and the order they come out in (ids ascend as seeds are found)
        XCTAssertEqual(legacy.blobs.map { $0.id }, rewritten.blobs.map { $0.id }, file: file, line: line)
        return b.count
    }

    private func legacyType(_ type: FullFrameBlobber.NeighborType) -> LegacyFullFrameBlobber.NeighborType {
        switch type {
        case .eight: return .eight
        case .fourCardinal: return .fourCardinal
        case .fourCorner: return .fourCorner
        }
    }

    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    // MARK: - synthetic

    /// Sparse bright peaks on a dim noisy floor with ties everywhere: the stable-sort question.
    func testSparsePeaksWithManyEqualValues() async {
        let w = 120, h = 90
        var rng = Rng(state: 1)
        var data = [UInt16](repeating: 0, count: w * h)
        for i in 0..<data.count { data[i] = UInt16(rng.next() % 4) * 1000 }          // floor, heavy ties
        for _ in 0..<60 {
            let cx = Int(rng.next() % UInt64(w)), cy = Int(rng.next() % UInt64(h))
            let peak = UInt16(10000 + (rng.next() % 5) * 5000)                      // ties among peaks
            for dy in -2...2 { for dx in -2...2 {
                let x = cx + dx, y = cy + dy
                if x >= 0, y >= 0, x < w, y < h {
                    let falloff = UInt16(max(0, 5 - abs(dx) - abs(dy)))
                    data[y * w + x] = max(data[y * w + x], peak / 5 * falloff)
                }
            } }
        }
        for type in [FullFrameBlobber.NeighborType.eight, .fourCardinal, .fourCorner] {
            let n = await compare(data, width: w, height: h, args: args(), neighborType: type, "sparse \(type)")
            XCTAssertGreaterThan(n, 5)
        }
    }

    /// A dense field of bright pixels: big blobs that grow past the contrast-size ramp, so the
    /// threshold changes while a blob is growing and queued pixels get refused and re-added.
    func testDenseFieldWhereTheContrastThresholdMovesDuringGrowth() async {
        let w = 90, h = 70
        var rng = Rng(state: 9)
        var data = [UInt16](repeating: 0, count: w * h)
        for i in 0..<data.count { data[i] = UInt16(7000 + rng.next() % 40000) }
        for (start, end, hi, lo) in [(5, 60, 40.0, 3.0), (10, 100, 30.0, 5.0), (3, 20, 60.0, 20.0)] {
            let n = await compare(data, width: w, height: h,
                                  args: args(startSize: start, endSize: end, startContrast: hi, endContrast: lo),
                                  "dense \(start)-\(end)")
            XCTAssertGreaterThan(n, 0)
        }
    }

    func testStreaksAndDimPixelsNearTheThreshold() async {
        let w = 100, h = 60
        var data = [UInt16](repeating: 0, count: w * h)
        for x in 10..<90 { data[(20 + x / 10) * w + x] = 30000 }                     // a diagonal streak
        for x in 10..<90 where x % 3 == 0 { data[(40) * w + x] = 5900 }              // just under the threshold
        for x in 10..<90 where x % 3 == 1 { data[(40) * w + x] = 6001 }              // just over
        _ = await compare(data, width: w, height: h, args: args(), "streak")
    }

    func testBoundsAndIgnoredLowerRows() async {
        let w = 80, h = 80
        var rng = Rng(state: 4)
        var data = [UInt16](repeating: 0, count: w * h)
        for i in 0..<data.count { data[i] = UInt16(rng.next() % 20) * 2500 }
        let bounds = BoundingBox(min: Coord(x: 10, y: 12), max: Coord(x: 60, y: 70))
        _ = await compare(data, width: w, height: h, args: args(), within: bounds, "bounds")
        var config = Config()
        config.ignoreLowerPixels = 25
        _ = await compare(data, width: w, height: h, args: args(), config: config, "ignoreLowerPixels")
        _ = await compare(data, width: w, height: h, args: args(), startingBlobID: 777, "starting id")
    }

    func testAnEmptyAndAnAllBrightImage() async {
        let w = 20, h = 20
        _ = await compare([UInt16](repeating: 0, count: w * h), width: w, height: h, args: args(), "empty")
        _ = await compare([UInt16](repeating: 40000, count: w * h), width: w, height: h, args: args(), "flat bright")
    }

    // MARK: - real subtraction images

    /// Neighbouring frames of the shipped test sequence, differenced and cropped: noise, stars
    /// and hot pixels as they really come out of the subtraction step.
    func testRealSubtractionImages() async throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("test_data/test_a7sii_10")
        let names = ["LRT_00080.jpg", "LRT_00081.jpg", "LRT_00082.jpg", "LRT_00083.jpg"]
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.appendingPathComponent(names[0]).path),
                          "test_data/test_a7sii_10 is not present")

        func gray(_ name: String) throws -> (UInt16Buffer, Int, Int) {
            let mat = try XCTUnwrap(MatWrapper.load(fromFilename: dir.appendingPathComponent(name).path))
            let image = try XCTUnwrap(PixelatedImage(mat: mat.ensure16Bits()!))
            guard case .sixteenBit(let buffer) = image.imageData else { throw XCTSkip("not 16 bit") }
            return (UInt16Buffer(Array(buffer)), image.width, image.height)
        }
        var checked = 0
        for pair in [(0, 1), (1, 2), (2, 3)] {
            let (a, w, h) = try gray(names[pair.0])
            let (b, _, _) = try gray(names[pair.1])
            let comps = a.values.count / (w * h)
            // crop (and take one channel) to keep the reference blobber quick
            let cropW = 700, cropH = 500, ox = 1800, oy = 1200
            var sub = [UInt16](repeating: 0, count: cropW * cropH)
            for y in 0..<cropH { for x in 0..<cropW {
                let i = ((oy + y) * w + (ox + x)) * comps
                let d = Int(a.values[i]) - Int(b.values[i])
                sub[y * cropW + x] = UInt16(max(0, min(65535, d * 4)))
            } }
            for variant in [args(), args(minIntensity: 3000, startContrast: 50, endContrast: 10)] {
                let n = await compare(sub, width: cropW, height: cropH, args: variant,
                                      "real pair \(pair) minIntensity \(variant.minPixelIntensity)")
                checked += n
            }
        }
        XCTAssertGreaterThan(checked, 0, "the real images produced no blobs, so nothing was compared")
    }

    private struct UInt16Buffer { let values: [UInt16]; init(_ v: [UInt16]) { values = v } }
}
