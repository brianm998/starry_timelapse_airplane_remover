import XCTest
import StarCore
@testable import star

/// Tests for the post-run temp cleanup, which deletes a finished run's working files.
///
/// It used to remove `star_temp_<sequence>/` wholesale, which took the saved config with
/// it. That made a run which completed normally the one kind of run that could not be
/// resumed: `star star_temp_<sequence>/config.json` had nothing to read. (Before
/// `e262031c` the file was never successfully written in the first place, so the two bugs
/// hid each other — fixing the write only moved the deletion to the end of the run.)
///
/// So cleanup empties the dir rather than removing it, sparing exactly the config.
/// `Config.jsonPath(named:)` decides which path that is, and is shared with
/// `Config.writeJson` so the file that gets written is the file that gets spared —
/// `StarCoreTests.WriteJsonTests` covers that resolution.
final class RemoveTempFilesTests: XCTestCase {

    private var scratch: String!

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory()
          + "/star-remove-temp-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: scratch,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// Builds the shape a real run leaves behind: a config alongside cache dirs, one of
    /// them non-empty, plus the generated cleanup.sh.
    private func makeTempDir(named name: String = "star_temp_seq") throws -> String {
        let tempDir = "\(scratch!)/\(name)"
        let fm = FileManager.default
        for dir in ["keypoints", "horizon", "aligned/nested"] {
            try fm.createDirectory(atPath: "\(tempDir)/\(dir)",
                                   withIntermediateDirectories: true)
        }
        try Data("frame".utf8)
          .write(to: URL(fileURLWithPath: "\(tempDir)/aligned/nested/0.tiff"))
        try Data("#!/bin/bash".utf8)
          .write(to: URL(fileURLWithPath: "\(tempDir)/cleanup.sh"))
        try Data("{}".utf8)
          .write(to: URL(fileURLWithPath: "\(tempDir)/config.json"))
        return tempDir
    }

    // MARK: - what survives

    func testTheSparedConfigSurvives() throws {
        let tempDir = try makeTempDir()

        try removeTempFiles(at: tempDir, sparing: "\(tempDir)/config.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir)/config.json"))
    }

    /// The point of sparing the file is that it stays reachable at the path a resume would
    /// name, so the dir holding it has to stay too.
    func testTheTempDirItselfSurvivesToHoldIt() throws {
        let tempDir = try makeTempDir()

        try removeTempFiles(at: tempDir, sparing: "\(tempDir)/config.json")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir),
                       ["config.json"])
    }

    /// Everything else is regenerable and is what the cleanup exists to reclaim —
    /// including populated subtrees, which need a recursive delete rather than a rmdir.
    func testEverythingElseGoes() throws {
        let tempDir = try makeTempDir()

        try removeTempFiles(at: tempDir, sparing: "\(tempDir)/config.json")

        for gone in ["keypoints", "horizon", "aligned", "aligned/nested/0.tiff",
                     "cleanup.sh"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: "\(tempDir)/\(gone)"),
                           "\(gone) should have been removed")
        }
    }

    // MARK: - paths

    /// A resume is given whatever the user typed, so the resolved config path is relative
    /// whenever that argument was, while `tempOutputPath` read out of the config file is
    /// absolute. Comparing the two as plain strings would spare nothing and delete the
    /// config — the thing this whole change exists to keep.
    func testARelativeSparedPathStillMatchesAnAbsoluteTempDir() throws {
        let tempDir = try makeTempDir()
        let cwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(scratch))

        try removeTempFiles(at: tempDir, sparing: "star_temp_seq/config.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempDir)/config.json"))
    }

    /// stard names an absolute session dir of its own, so the config it saves is nowhere
    /// under the temp dir. Nothing there is worth keeping then, and the dir goes as it
    /// always did rather than being left behind empty.
    func testATempDirWithNothingWorthKeepingIsRemovedEntirely() throws {
        let tempDir = try makeTempDir()
        let elsewhere = "\(scratch!)/session-dir/config.json"

        try removeTempFiles(at: tempDir, sparing: elsewhere)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir))
    }

    /// A run that failed early enough may never have built the temp dir. Cleanup runs in
    /// `try?` at the call site, but reporting rather than throwing keeps that from hiding
    /// a real failure.
    func testAMissingTempDirIsNotAnError() throws {
        XCTAssertNoThrow(
          try removeTempFiles(at: "\(scratch!)/never-created",
                              sparing: "\(scratch!)/never-created/config.json")
        )
    }
}
