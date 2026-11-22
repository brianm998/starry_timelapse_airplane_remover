import XCTest
@testable import StarCppBridge

/// The `.kpb` binary feature-file layout (`STARKP01`) and the legacy YAML it replaced.
final class OCVFeatureSetBinaryTests: XCTestCase {

    private func makeStarField(width: Int, height: Int, count: Int) -> MatWrapper {
        var state: UInt64 = 12345
        func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt16(next() % 300) }
        for _ in 0..<count {
            let cx = 8 + next() % (width - 16), cy = 8 + next() % (height - 16)
            for dy in -3...3 { for dx in -3...3 {
                let v = max(0, 40000 - 4000 * (dx * dx + dy * dy))
                data[(cy + dy) * width + cx + dx] = UInt16(clamping: v)
            } }
        }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 1),
                          bytesPerRow: width * 2, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    private func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "kpb-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func features() throws -> OCVFeatureSet {
        let img = makeStarField(width: 512, height: 384, count: 80)
        let f = try XCTUnwrap(ImageAligner.debugSiftReference(img, mask: nil, nfeatures: 300))
        XCTAssertGreaterThan(f.keypointCount, 0)
        return f
    }

    func testRoundTrip() throws {
        let dir = try tempDir()
        let original = try features()
        let kpb = "\(dir)/a.kpb"
        XCTAssertTrue(original.write(toFilename: kpb))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["a.kpb"],
                       "a temp file was left behind")
        let magic = try Data(contentsOf: URL(fileURLWithPath: kpb)).prefix(8)
        XCTAssertEqual(String(data: magic, encoding: .ascii), "STARKP01")

        let back = try XCTUnwrap(OCVFeatureSet.load(fromFilename: kpb))
        XCTAssertEqual(back.keypointCount, original.keypointCount)
        XCTAssertEqual(back.starCount, original.starCount)
        XCTAssertEqual(back.descriptorRows, original.descriptorRows)
        XCTAssertEqual(back.descriptorCols, original.descriptorCols)
        XCTAssertEqual(back.descriptorType, original.descriptorType)
        let a = original.keypointPositions(), b = back.keypointPositions()
        for i in 0..<a.count { XCTAssertEqual(a[i].x, b[i].x); XCTAssertEqual(a[i].y, b[i].y) }

        // YAML carries every field of keypoints, descriptors and stars: identical text means
        // identical content.
        XCTAssertTrue(original.write(toFilename: "\(dir)/o.yaml"))
        XCTAssertTrue(back.write(toFilename: "\(dir)/b.yaml"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: "\(dir)/o.yaml")),
                       try Data(contentsOf: URL(fileURLWithPath: "\(dir)/b.yaml")))
        // And the binary is smaller.
        let ksize = try FileManager.default.attributesOfItem(atPath: kpb)[.size] as! Int
        let ysize = try FileManager.default.attributesOfItem(atPath: "\(dir)/o.yaml")[.size] as! Int
        XCTAssertLessThan(ksize * 2, ysize)
    }

    func testLegacyYamlLoads() throws {
        let dir = try tempDir()
        let original = try features()
        XCTAssertTrue(original.write(toFilename: "\(dir)/old.yaml"))
        let back = try XCTUnwrap(OCVFeatureSet.load(fromFilename: "\(dir)/old.yaml"))
        XCTAssertEqual(back.keypointCount, original.keypointCount)
        XCTAssertEqual(back.descriptorRows, original.descriptorRows)
    }

    func testTruncatedBinaryFailsToLoad() throws {
        let dir = try tempDir()
        let original = try features()
        let kpb = "\(dir)/t.kpb"
        XCTAssertTrue(original.write(toFilename: kpb))
        let data = try Data(contentsOf: URL(fileURLWithPath: kpb))
        try data.prefix(data.count / 2).write(to: URL(fileURLWithPath: kpb))
        XCTAssertNil(OCVFeatureSet.load(fromFilename: kpb))
    }
}
