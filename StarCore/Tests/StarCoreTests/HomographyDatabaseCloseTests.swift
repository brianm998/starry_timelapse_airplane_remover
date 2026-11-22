import XCTest
import Foundation
@testable import StarCore

final class HomographyDatabaseCloseTests: XCTestCase {

    private func makeDir() throws -> String {
        let dir = NSTemporaryDirectory() + "hdb-close-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// Descriptors of this process that point at a homography.db file.
    private func openDescriptors(under dir: String) -> Int {
        let real = realpath(dir, nil).map { String(cString: $0) } ?? dir
        var count = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let fd = Int32(name) else { continue }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
            if fcntl(fd, F_GETPATH, &buf) == 0 {
                let path = String(cString: buf)
                if path.hasPrefix(real) && path.contains("homography.db") { count += 1 }
            }
        }
        return count
    }

    private func sample() -> HomographyResultsCodable {
        HomographyResultsCodable(for: 1, with: [])
    }

    func testCloseReleasesFiles() async throws {
        let dir = try makeDir()
        let db = HomographyDatabase(tempOutputPath: dir)
        try await db.write(frameIndex: 1, type: .star, results: sample())
        let before = openDescriptors(under: dir)
        XCTAssertGreaterThan(before, 0)
        await db.close()
        XCTAssertEqual(openDescriptors(under: dir), 0)
        let stored = try await db.read(frameIndex: 1, type: .star)
        XCTAssertNotNil(stored)   // reopens, and the data survived
        await db.close()
    }

    func testReopensAfterClose() async throws {
        let dir = try makeDir()
        let db = HomographyDatabase(tempOutputPath: dir)
        try await db.write(frameIndex: 1, type: .star, results: sample())
        await db.close()
        try await db.write(frameIndex: 2, type: .earth, results: sample())
        let r = try await db.read(frameIndex: 2, type: .earth)
        XCTAssertNotNil(r)
        await db.close()
    }

    func testDeinitCloses() async throws {
        let dir = try makeDir()
        var db: HomographyDatabase? = HomographyDatabase(tempOutputPath: dir)
        try await db!.write(frameIndex: 1, type: .star, results: sample())
        XCTAssertGreaterThan(openDescriptors(under: dir), 0)
        db = nil
        XCTAssertEqual(openDescriptors(under: dir), 0)
    }
}
