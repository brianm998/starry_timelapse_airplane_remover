import XCTest
@testable import StarCore

/// `Config.writeJson` is what makes a run resumable: `star <seq>` is supposed to leave a
/// config.json in its temp dir that `star <seq>_temp/config.json` can be restarted from.
///
/// It never did. On a fresh image sequence the first write happens in `Processor.init`,
/// long before `ImageAccessor.mkdirs()` builds the temp dir tree, and the write went
/// through `FileManager.createFile(atPath:contents:attributes:)` with its `Bool` result
/// dropped on the floor. createFile returns false — it does not throw — when the parent
/// directory is missing, so every fresh run logged "creating <path>" and wrote nothing,
/// and the log line read as success either way.
///
/// These tests pin both halves of the repair: the dir gets created, and the destination
/// is worked out from the filename rather than guessed at with a prefix comparison.
final class WriteJsonTests: XCTestCase {

    private var scratch = ""

    override func setUpWithError() throws {
        scratch = NSTemporaryDirectory()
          + "/star-writejson-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch,
                                               withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    private func config(tempOutputPath: String) -> Config {
        var config = Config()
        config.tempOutputPath = tempOutputPath
        return config
    }

    // MARK: - the dir has to be created

    /// The actual bug: nothing creates tempOutputPath before the first write, so writeJson
    /// has to make it itself.
    func testItCreatesATempDirThatDoesNotExistYet() {
        let tempPath = "\(scratch)/star_temp_seq"
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath),
                       "precondition: the temp dir tree has not been built yet")

        config(tempOutputPath: tempPath).writeJson(named: "config.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempPath)/config.json"),
                      "a fresh run's config.json is the only thing that makes the run "
                      + "resumable, so a missing parent dir cannot be a silent no-op")
    }

    /// Whatever was written has to be a config, not an empty file left behind by a
    /// half-failed write.
    func testWhatItWritesCanBeReadBack() throws {
        let tempPath = "\(scratch)/star_temp_seq"
        var saved = config(tempOutputPath: tempPath)
        saved.imageSequenceDirname = "seq"

        saved.writeJson(named: "config.json")

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(tempPath)/config.json"))
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.imageSequenceDirname, "seq")
        XCTAssertEqual(decoded.tempOutputPath, tempPath)
    }

    // MARK: - where the file lands

    /// A bare filename belongs under tempOutputPath. This is how a fresh cli run and
    /// decision_tree_generator both call it.
    func testABareFilenameGoesUnderTempOutputPath() {
        let tempPath = "\(scratch)/star_temp_seq"

        config(tempOutputPath: tempPath).writeJson(named: "config.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempPath)/config.json"))
    }

    /// A filename that already carries a directory names its own destination. The cli hands
    /// back exactly what the user typed on resume, so this is usually relative while the
    /// tempOutputPath read out of that same file is absolute — the old
    /// `filename.hasPrefix(tempOutputPath)` test only recognised the absolute-and-identical
    /// case and appended the rest, doubling the dirname.
    func testARelativePathIsNotResolvedAgainstAnAbsoluteTempOutputPath() throws {
        let tempPath = "\(scratch)/star_temp_seq"
        try FileManager.default.createDirectory(atPath: tempPath,
                                               withIntermediateDirectories: true)
        let cwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(scratch))

        // the shape of a resume: relative path in, absolute tempOutputPath in the config
        config(tempOutputPath: tempPath).writeJson(named: "star_temp_seq/config.json",
                                                   overwrite: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(tempPath)/config.json"))
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: "\(tempPath)/star_temp_seq"),
          "resolving the relative path against the absolute tempOutputPath would write "
          + "to star_temp_seq/star_temp_seq/config.json"
        )
    }

    /// An absolute path is left alone even when it has nothing to do with tempOutputPath,
    /// which is how stard names its session dir.
    func testAnAbsolutePathElsewhereIsHonoured() {
        let elsewhere = "\(scratch)/session-dir"

        config(tempOutputPath: "\(scratch)/star_temp_seq")
          .writeJson(named: "\(elsewhere)/config.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(elsewhere)/config.json"))
    }

    // MARK: - through ConfigManager

    /// The layer everything but the cli actually goes through. `ConfigManager.save()` hands
    /// its own `_jsonFilename` to `writeJson`, and for stard that is an absolute path in a
    /// scratch session dir with no relation to `tempOutputPath`.
    ///
    /// This used not to work, and the daemon carried a hand-rolled writer and a scattering
    /// of `save: false` to route around it: before the prefix test above became a
    /// `deletingLastPathComponent`, an absolute path that was not literally prefixed by
    /// `tempOutputPath` got appended to it, so the file landed at
    /// `<tempOutputPath>//scratch/<uuid>/config.json`.
    func testConfigManagerSavesToAnAbsoluteFilename() async throws {
        let sessionDir = "\(scratch)/session-dir"
        try FileManager.default.createDirectory(atPath: sessionDir,
                                                withIntermediateDirectories: true)
        var starting = config(tempOutputPath: "\(scratch)/star_temp_seq")
        starting.imageSequenceDirname = "seq"

        let manager = await ConfigManager(configFilename: "\(sessionDir)/config.json",
                                          config: starting)
        var updated = await manager.config()
        updated.imageWidth = 4240
        await manager.update(updated)          // save: true, the default
        await manager.flush()                  // the write is async and coalesced

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(sessionDir)/config.json"))
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.imageWidth, 4240)
        XCTAssertEqual(decoded.imageSequenceDirname, "seq")
    }

    /// And a bare filename still lands under `tempOutputPath`, which is what a fresh cli run
    /// hands `ConfigManager`.
    func testConfigManagerSavesABareFilenameUnderTempOutputPath() async throws {
        let tempPath = "\(scratch)/star_temp_seq"
        let manager = await ConfigManager(configFilename: "config.json",
                                          config: config(tempOutputPath: tempPath))
        var updated = await manager.config()
        updated.imageWidth = 1234
        await manager.update(updated)
        await manager.flush()                  // the write is async and coalesced

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(tempPath)/config.json"))
        XCTAssertEqual(try JSONDecoder().decode(Config.self, from: data).imageWidth, 1234)
    }

    // MARK: - overwrite

    func testItRefusesToClobberWithoutOverwrite() throws {
        let tempPath = "\(scratch)/star_temp_seq"
        try FileManager.default.createDirectory(atPath: tempPath,
                                               withIntermediateDirectories: true)
        let path = "\(tempPath)/config.json"
        try Data("original".utf8).write(to: URL(fileURLWithPath: path))

        config(tempOutputPath: tempPath).writeJson(named: "config.json")

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "original")
    }

    func testOverwriteReplacesTheWholeFile() throws {
        let tempPath = "\(scratch)/star_temp_seq"
        try FileManager.default.createDirectory(atPath: tempPath,
                                               withIntermediateDirectories: true)
        let path = "\(tempPath)/config.json"
        // longer than the json about to replace it, so a truncating write is the only
        // thing that leaves valid json behind
        try Data(String(repeating: "x", count: 64 * 1024).utf8)
          .write(to: URL(fileURLWithPath: path))

        config(tempOutputPath: tempPath).writeJson(named: "config.json", overwrite: true)

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNoThrow(try JSONDecoder().decode(Config.self, from: data))
    }
}
