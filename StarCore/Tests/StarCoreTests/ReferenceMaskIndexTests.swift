import XCTest
@testable import StarCore

/// The per-directory list of painted references that replaced a per-frame stat of every frame.
final class ReferenceMaskIndexTests: XCTestCase {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("refindex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func build(_ dir: URL, frames: Int) -> (Set<String>) -> [Int: String] {
        { names in
            var found: [Int: String] = [:]
            for i in 0..<frames where names.contains("f\(i).tif") {
                found[i] = dir.appendingPathComponent("f\(i).tif").path
            }
            return found
        }
    }

    func testTheDirectoryIsListedOnceAndReusedUntilItChanges() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("f2.tif").path, contents: Data([1]))

        let index = ReferenceMaskIndex()
        let first = index.index(of: dir, build: build(dir, frames: 6))
        XCTAssertEqual(Set(first.keys), [2])
        _ = index.index(of: dir, build: build(dir, frames: 6))
        _ = index.index(of: dir, build: build(dir, frames: 6))
        XCTAssertEqual(index.builds, 1, "an unchanged directory was listed again")

        // painting another reference adds a file, which changes the directory
        Thread.sleep(forTimeInterval: 0.02)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("f4.tif").path, contents: Data([1]))
        let after = index.index(of: dir, build: build(dir, frames: 6))
        XCTAssertEqual(Set(after.keys), [2, 4])
        XCTAssertEqual(index.builds, 2)
    }

    func testARemovedReferenceDisappears() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in [1, 3] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i).tif").path, contents: Data([1]))
        }
        let index = ReferenceMaskIndex()
        XCTAssertEqual(Set(index.index(of: dir, build: build(dir, frames: 5)).keys), [1, 3])
        Thread.sleep(forTimeInterval: 0.02)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("f1.tif"))
        XCTAssertEqual(Set(index.index(of: dir, build: build(dir, frames: 5)).keys), [3])
    }

    func testExplicitInvalidationForcesARebuild() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = ReferenceMaskIndex()
        _ = index.index(of: dir, build: build(dir, frames: 3))
        index.invalidate(directory: dir)
        _ = index.index(of: dir, build: build(dir, frames: 3))
        XCTAssertEqual(index.builds, 2)
    }

    func testAMissingDirectoryIsEmptyAndNeverCached() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let index = ReferenceMaskIndex()
        XCTAssertTrue(index.index(of: dir, build: build(dir, frames: 3)).isEmpty)
        XCTAssertTrue(index.index(of: dir, build: build(dir, frames: 3)).isEmpty)
        XCTAssertEqual(index.builds, 2)   // no stamp, so it is not trusted
    }
}
