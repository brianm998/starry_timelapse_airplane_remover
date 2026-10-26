import XCTest
import StarCore
import StarCppBridge
@testable import stard

/// The label image is kept while a frame's outlier groups are the same ones, and written atomically.
final class LabelImageCacheTests: XCTestCase {

    private func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> BoundingBox {
        BoundingBox(min: Coord(x: x0, y: y0), max: Coord(x: x1, y: y1))
    }

    func testTheVersionIsStableAndIgnoresOrder() {
        let a: [(UInt16, BoundingBox, Int)] = [(1, box(0, 0, 4, 4), 10), (2, box(10, 10, 14, 14), 7), (3, box(30, 5, 33, 9), 3)]
        let shuffled = [a[2], a[0], a[1]]
        XCTAssertEqual(LabelImageCache.version(of: a, width: 100, height: 50),
                       LabelImageCache.version(of: shuffled, width: 100, height: 50))
    }

    func testAnyChangeToTheGroupsChangesTheVersion() {
        let base: [(UInt16, BoundingBox, Int)] = [(1, box(0, 0, 4, 4), 10), (2, box(10, 10, 14, 14), 7)]
        let v = LabelImageCache.version(of: base, width: 100, height: 50)
        XCTAssertNotEqual(v, LabelImageCache.version(of: Array(base.dropLast()), width: 100, height: 50), "a group was removed")
        XCTAssertNotEqual(v, LabelImageCache.version(of: base + [(3, box(1, 1, 2, 2), 1)], width: 100, height: 50), "a group was added")
        XCTAssertNotEqual(v, LabelImageCache.version(of: [(1, box(0, 0, 4, 4), 10), (2, box(10, 10, 14, 15), 7)], width: 100, height: 50), "bounds moved")
        XCTAssertNotEqual(v, LabelImageCache.version(of: [(1, box(0, 0, 4, 4), 10), (2, box(10, 10, 14, 14), 8)], width: 100, height: 50), "size changed")
        XCTAssertNotEqual(v, LabelImageCache.version(of: [(1, box(0, 0, 4, 4), 10), (9, box(10, 10, 14, 14), 7)], width: 100, height: 50), "id changed")
        XCTAssertNotEqual(v, LabelImageCache.version(of: base, width: 101, height: 50), "frame size changed")
    }

    func testTheCacheIsCurrentOnlyForTheRecordedVersionWhileTheFileExists() throws {
        let dir = NSTemporaryDirectory() + "labelcache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/frame_0_label.png"
        let cache = LabelImageCache()

        XCTAssertFalse(cache.isCurrent(key: "s/0", version: 5, path: path), "nothing recorded yet")
        cache.record(key: "s/0", version: 5)
        XCTAssertFalse(cache.isCurrent(key: "s/0", version: 5, path: path), "the file is not there")
        FileManager.default.createFile(atPath: path, contents: Data([1]))
        XCTAssertTrue(cache.isCurrent(key: "s/0", version: 5, path: path))
        XCTAssertFalse(cache.isCurrent(key: "s/0", version: 6, path: path), "the groups changed")
        XCTAssertFalse(cache.isCurrent(key: "s/1", version: 5, path: path), "another frame")
    }

    func testAtomicWriteLeavesOnlyTheFinalFile() throws {
        let dir = NSTemporaryDirectory() + "labelwrite-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/frame_3_label.png"
        var pixels = [UInt16](repeating: 0, count: 16 * 8)
        pixels[5] = 7
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            let mat = MatWrapper(width: 16, height: 8, cvType: 2, bytesPerRow: 32, data: raw.baseAddress!, takeOwnership: false)
            return LabelImageCache.writeAtomically(mat, to: path)
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["frame_3_label.png"], "a temp file was left behind")
        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(loaded.cols, 16)
        XCTAssertEqual(loaded.rows, 8)
    }

    /// Rewriting over an existing file replaces it in one step.
    func testAtomicWriteReplacesAnExistingFile() throws {
        let dir = NSTemporaryDirectory() + "labelreplace-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/x_label.png"
        for width in [8, 12] {
            var pixels = [UInt16](repeating: 1, count: width * 4)
            let ok = pixels.withUnsafeMutableBytes { raw in
                LabelImageCache.writeAtomically(
                  MatWrapper(width: width, height: 4, cvType: 2, bytesPerRow: width * 2, data: raw.baseAddress!, takeOwnership: false),
                  to: path)
            }
            XCTAssertTrue(ok)
        }
        let loaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(loaded.cols, 12)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).count, 1)
    }
}
