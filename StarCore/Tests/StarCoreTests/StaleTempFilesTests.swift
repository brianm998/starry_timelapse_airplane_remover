import XCTest
@testable import StarCore

final class StaleTempFilesTests: XCTestCase {

    func testRecognisesTheWritersTempNames() {
        XCTAssertEqual(StaleTempFiles.writerPID(inFileName: "LRT_00080.tmp.4242-17.tif"), 4242)
        XCTAssertEqual(StaleTempFiles.writerPID(inFileName: "frame.tmp.9-0.jpg"), 9)
        XCTAssertEqual(StaleTempFiles.writerPID(inFileName: "keypoints_3.tmp.77-5.yml"), 77)
        XCTAssertEqual(StaleTempFiles.writerPID(inFileName: "noext.tmp.12-3"), 12)
    }

    func testIgnoresEverythingElse() {
        for name in ["LRT_00080.tif", "my.tmp.tif", "a.tmp.12.tif", "a.tmp.x-1.tif", "tmp.12-3.tif",
                     "report.tmp.12-3.tif.bak", "a.tmp.12-3.tif.old"] {
            XCTAssertNil(StaleTempFiles.writerPID(inFileName: name), name)
        }
    }

    private func makeTree() throws -> (String, [String: String]) {
        let root = NSTemporaryDirectory() + "stale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)
        let files = ["dead": "a.tmp.31001-1.tif", "alive": "b.tmp.31002-1.tif", "real": "c.tif",
                     "nested": "sub/d.tmp.31001-9.yml", "own": "e.tmp.\(ProcessInfo.processInfo.processIdentifier)-1.tif"]
        for (_, name) in files { FileManager.default.createFile(atPath: "\(root)/\(name)", contents: Data([1])) }
        return (root, files)
    }

    func testRemovesOnlyFilesWhoseWriterIsGone() throws {
        let (root, files) = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let removed = StaleTempFiles.clean(in: [root]) { pid in pid == 31002 }   // only 31002 is alive

        XCTAssertEqual(removed, 2)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: "\(root)/\(files["dead"]!)"))
        XCTAssertFalse(fm.fileExists(atPath: "\(root)/\(files["nested"]!)"), "subdirectories are searched")
        XCTAssertTrue(fm.fileExists(atPath: "\(root)/\(files["alive"]!)"), "a live writer's file was removed")
        XCTAssertTrue(fm.fileExists(atPath: "\(root)/\(files["real"]!)"), "a real file was removed")
        XCTAssertTrue(fm.fileExists(atPath: "\(root)/\(files["own"]!)"), "a write of our own may be in flight")
    }

    func testAMissingOrEmptyDirectoryIsFine() {
        XCTAssertEqual(StaleTempFiles.clean(in: ["", "/nonexistent-\(UUID().uuidString)"]), 0)
    }

    func testTheLivenessCheckKnowsThisProcessAndNotAnImpossibleOne() {
        XCTAssertTrue(StaleTempFiles.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(StaleTempFiles.processIsAlive(2_000_000_000))
    }
}
