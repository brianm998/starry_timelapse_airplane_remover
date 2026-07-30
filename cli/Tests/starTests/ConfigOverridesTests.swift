import XCTest
import StarCore
@testable import star

/// star's positional argument is either an image sequence dirname or a previously saved
/// `config.json`, and those used to be two separate wirings of the command line onto a
/// `Config`. Only the sequence one was complete. The config file branch loaded the
/// config, applied `writeOutlierClassificationValues`, and dropped everything else on
/// the floor without a word — so `star --log-op-memory --keypoint-divisor 2
/// foo/config.json` ran at full resolution and logged no op memory at all. That is how
/// it was found: `--log-op-memory` produced no output while measuring a merge.
///
/// The fix is that there is now one wiring, `ConfigOverrides`, and both branches apply
/// it. These tests cover both halves of what that has to mean:
///
///  - a flag the user typed reaches the config on either path
///  - a flag the user did not type leaves the saved config's own value alone
///
/// The second is the one with teeth. The `@Flag`s are non-optional `Bool`s defaulting to
/// false with no `--no-` form, so "false" and "the user did not type it" are the same
/// value; assigning them unconditionally would silently turn off a saved config's
/// `alignmentKeypointDetectionDivisor` on every resume that forgot to repeat the flag.
final class ConfigOverridesTests: XCTestCase {

    /// A stand-in for a saved config: every field an override can touch, set to
    /// something that is not the default, so that an unwanted write shows up as a
    /// changed value rather than as the same default twice.
    private func savedConfig() -> Config {
        var c = Config()
        c.cleanMethod = .automatic(true)
        c.detectionType = .excessive
        c.finalOutputDir = "/saved/final/out"
        c.writeOutlierGroupFiles = true
        c.writeFramePreviewFiles = true
        c.writeFrameProcessedPreviewFiles = true
        c.writeFrameThumbnailFiles = true
        c.writeOutlierClassificationValues = true
        c.writeOutputFiles = false
        c.horizonDetectionEnabled = false
        c.tripodHeadWasMoving = true
        c.alignmentKeypointDetectionDivisor = 2.0
        c.mergeStreamingThresholdMB = 1024
        c.maxConcurrentKeypointOps = 3
        c.horizonReservationFloorMB = 1200
        c.numberOfFramesToProcessConcurrently = 5
        c.ignoreLowerPixels = 700
        return c
    }

    /// Every flag `ConfigOverrides` carries, each with a value distinct from both the
    /// StarCore default and the `savedConfig()` value above.
    ///
    /// `-s` appears in its `--no-` form because it is the one flag whose config field is a
    /// `Bool` the saved config already holds the opposite of: `savedConfig()` skips output
    /// files, so the override that has to be visible here is the one turning them back on.
    private static let everyFlag = [
      "--clean-method", "selective",
      "--detection-type", "mild",
      "--write-outlier-group-files",
      "--write-outlier-classification-values",
      "--no-skip-output-files",
      "--no-horizon",
      "--moving-camera",
      "--keypoint-divisor", "1.5",
      "--merge-streaming-threshold-mb", "2048",
      "--max-keypoint-ops", "7",
      "--horizon-reservation-floor-mb", "450",
      "--num-concurrent-renders", "1",
      "--ignore-lower-pixels", "42",
      "/some/star_temp_seq/config.json",
      "/some/final/out",                 // the finalOutputDirname positional
    ]

    // MARK: - what the command line does, and does not, say

    func testEveryFlagOverridesASavedConfig() throws {
        let cli = try StarCli.parse(Self.everyFlag)
        var c = savedConfig()
        cli.configOverrides.apply(to: &c)

        XCTAssertEqual(c.cleanMethod, .selective)
        XCTAssertEqual(c.detectionType, .mild)
        XCTAssertEqual(c.finalOutputDir, "/some/final/out")
        XCTAssertEqual(c.writeOutlierGroupFiles, true)
        XCTAssertEqual(c.writeOutlierClassificationValues, true)
        XCTAssertEqual(c.writeOutputFiles, true, "--no-skip-output-files turns rendering on")
        XCTAssertEqual(c.horizonDetectionEnabled, false, "--no-horizon turns it off")
        XCTAssertEqual(c.tripodHeadWasMoving, true)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.5)
        XCTAssertEqual(c.mergeStreamingThresholdMB, 2048)
        XCTAssertEqual(c.maxConcurrentKeypointOps, 7)
        XCTAssertEqual(c.horizonReservationFloorMB, 450)
        XCTAssertEqual(c.numberOfFramesToProcessConcurrently, 1)
        XCTAssertEqual(c.ignoreLowerPixels, 42)
    }

    /// The reported bug, on a config whose values are all StarCore defaults: the flags
    /// have to be visible in the config the run is about to use.
    func testTheFlagsFromTheBugReportReachADefaultConfig() throws {
        let cli = try StarCli.parse(["--log-op-memory",
                                     "--keypoint-divisor", "2",
                                     "/some/star_temp_seq/config.json"])
        var c = Config()
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
        cli.configOverrides.apply(to: &c)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 2.0)

        // --log-op-memory is a process global rather than a config field, so all the
        // parse can show is that it was seen; that it is applied on both paths is
        // testLogOpMemoryIsAppliedBeforeEitherInputPath below.
        XCTAssertTrue(cli.logOpMemory)
    }

    /// The other half, and the reason the flags are carried as optionals: an unmentioned
    /// flag must not overwrite the saved config with a default.
    func testASavedConfigKeepsEverythingTheCommandLineDoesNotMention() throws {
        let cli = try StarCli.parse(["/some/star_temp_seq/config.json"])
        let saved = savedConfig()
        var c = saved
        cli.configOverrides.apply(to: &c)

        XCTAssertEqual(c.cleanMethod, saved.cleanMethod)
        XCTAssertEqual(c.detectionType, saved.detectionType)
        XCTAssertEqual(c.finalOutputDir, saved.finalOutputDir)
        XCTAssertEqual(c.writeOutlierGroupFiles, true)
        XCTAssertEqual(c.writeFramePreviewFiles, true)
        XCTAssertEqual(c.writeFrameProcessedPreviewFiles, true)
        XCTAssertEqual(c.writeFrameThumbnailFiles, true)
        XCTAssertEqual(c.writeOutlierClassificationValues, true,
                       "-W absent means the user said nothing, not that a config which "
                       + "asked for classification values should stop writing them")
        XCTAssertEqual(c.writeOutputFiles, false,
                       "neither -s nor --no-skip-output-files was typed, so the saved "
                       + "outlier-data-only setting stands")
        XCTAssertEqual(c.horizonDetectionEnabled, false)
        XCTAssertEqual(c.tripodHeadWasMoving, true)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 2.0,
                       "a bool @Flag defaults to false, which is indistinguishable from "
                       + "absent — applying it would undo the saved setting")
        XCTAssertEqual(c.mergeStreamingThresholdMB, 1024)
        XCTAssertEqual(c.maxConcurrentKeypointOps, 3)
        XCTAssertEqual(c.horizonReservationFloorMB, 1200)
        XCTAssertEqual(c.numberOfFramesToProcessConcurrently, 5)
        XCTAssertEqual(c.ignoreLowerPixels, 700)
    }

    /// 0 is a real value for these three — never stream, no keypoint cap, no horizon
    /// floor — so passing 0 has to reach the config rather than read as unset.
    func testAnExplicitZeroIsAnOverrideLikeAnyOther() throws {
        let cli = try StarCli.parse(["--merge-streaming-threshold-mb", "0",
                                     "--max-keypoint-ops", "0",
                                     "--horizon-reservation-floor-mb", "0",
                                     "/some/star_temp_seq/config.json"])
        var c = savedConfig()
        cli.configOverrides.apply(to: &c)

        XCTAssertEqual(c.mergeStreamingThresholdMB, 0)
        XCTAssertEqual(c.maxConcurrentKeypointOps, 0)
        XCTAssertEqual(c.horizonReservationFloorMB, 0)
    }

    /// The sequence path builds its `Config` from the constructor's defaults now that the
    /// flags no longer go in as constructor arguments, so those defaults have to still be
    /// what a plain run gets.
    func testAPlainSequenceRunStillGetsTheOldDefaults() throws {
        let cli = try StarCli.parse(["/some/image/sequence"])
        var c = Config(outputPath: "/some/image",
                       imageSequenceName: "sequence",
                       imageSequencePath: "/some/image",
                       writeOutlierGroupFiles: false,
                       writeFramePreviewFiles: false,
                       writeFrameProcessedPreviewFiles: false,
                       writeFrameThumbnailFiles: false)
        cli.configOverrides.apply(to: &c)

        XCTAssertEqual(c.cleanMethod, .automatic(false))
        XCTAssertEqual(c.detectionType, .strong)
        XCTAssertEqual(c.horizonDetectionEnabled, true)
        XCTAssertEqual(c.tripodHeadWasMoving, false)
        XCTAssertEqual(c.alignmentKeypointDetectionDivisor, 1.0)
        XCTAssertEqual(c.writeOutlierGroupFiles, false)
        XCTAssertEqual(c.writeOutputFiles, true, "a plain run renders")
        XCTAssertNil(c.finalOutputDir)
    }

    /// `-w` has always driven the previews and thumbnails alongside the group files.
    func testWriteOutlierGroupFilesDrivesAllFourFields() throws {
        let cli = try StarCli.parse(["-w", "/some/star_temp_seq/config.json"])
        var c = Config()
        cli.configOverrides.apply(to: &c)

        XCTAssertTrue(c.writeOutlierGroupFiles)
        XCTAssertTrue(c.writeFramePreviewFiles)
        XCTAssertTrue(c.writeFrameProcessedPreviewFiles)
        XCTAssertTrue(c.writeFrameThumbnailFiles)
    }

    // MARK: - -s, and the flag that was deleted instead

    /// `-s` was declared and never read, so it silently did nothing. It now drives
    /// `Config.writeOutputFiles`, which `FrameAirplaneRemover` has always honoured.
    ///
    /// It is the only flag here with three states, and it needs all three. `-s` is the one
    /// flag that takes output away, and the override is saved into config.json like every
    /// other one, so if absence meant "render" then no config could keep the setting
    /// across a resume, and if absence meant "skip" then nothing could ever undo it.
    func testSkipOutputFilesHasThreeStatesAndNeedsAllOfThem() throws {
        var skipped = Config()
        XCTAssertTrue(skipped.writeOutputFiles, "rendering is the default")
        try StarCli.parse(["-s", "/some/seq"]).configOverrides.apply(to: &skipped)
        XCTAssertFalse(skipped.writeOutputFiles, "-s means outlier data only")

        var unmentioned = Config()
        unmentioned.writeOutputFiles = false
        try StarCli.parse(["/some/star_temp_seq/config.json"])
            .configOverrides.apply(to: &unmentioned)
        XCTAssertFalse(unmentioned.writeOutputFiles,
                       "a resume that repeats no flags keeps what the config holds")

        var renderedAgain = Config()
        renderedAgain.writeOutputFiles = false
        try StarCli.parse(["--no-skip-output-files", "/some/star_temp_seq/config.json"])
            .configOverrides.apply(to: &renderedAgain)
        XCTAssertTrue(renderedAgain.writeOutputFiles, "and the --no- form is the way back")
    }

    /// `-s` only does anything because `Processor` hands the config field to every frame.
    /// Checking `run()`/`process()` for real needs an image sequence on disk and then
    /// processes it, so this is the syntactic property instead — the same approach the
    /// branch tests below take, and it fails if that line goes back to a literal `true`.
    func testProcessorPassesTheConfigsWriteOutputFilesToEachFrame() throws {
        let source = try cliSource(named: "Processor.swift")
        XCTAssertTrue(source.contains("class Processor"), "did not find Processor.swift itself")
        XCTAssertTrue(source.contains("writeOutputFiles: config.writeOutputFiles"),
                      "Processor no longer passes the config's writeOutputFiles to "
                      + "FrameAirplaneRemover, so --skip-output-files does nothing")
    }

    // `-L`/`--last-frame` was the other flag declared and never read.  It was deleted here
    // rather than implemented, because `FrameGraphBuilder.build`'s `startIndex`/`endIndex`
    // was honored by the horizon and keypoint stages only, and this file asserted that it
    // was rejected so it could not come back as a no-op.  `FrameGraphRange` fixed the
    // range, the flag is implemented, and that assertion is now `LastFrameTests` — which
    // covers the same concern by pinning the wiring itself rather than the flag's absence.
    // `testTheLastFrameFlagIsNotAConfigOverride` below is the half that belongs here.

    // MARK: - through an actual config.json

    /// The same thing end to end over the file a resume really reads, so that a config
    /// which does not mention a field still keeps StarCore's default for it, and one
    /// that does keeps its own.
    func testOverridesLandOnAConfigDecodedFromDisk() throws {
        var saved = Config()
        saved.alignmentKeypointDetectionDivisor = 2.0
        saved.mergeStreamingThresholdMB = 1024
        saved.ignoreLowerPixels = 700
        saved.writeOutputFiles = false

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("star-config-overrides-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(saved).write(to: file)

        var untouched = try Config.read(fromJsonFilename: file.path)
        try StarCli.parse([file.path]).configOverrides.apply(to: &untouched)
        XCTAssertEqual(untouched.alignmentKeypointDetectionDivisor, 2.0)
        XCTAssertEqual(untouched.mergeStreamingThresholdMB, 1024)
        XCTAssertEqual(untouched.ignoreLowerPixels, 700)
        XCTAssertFalse(untouched.writeOutputFiles,
                       "Config has to decode writeOutputFiles, or -s survives only until "
                       + "the config is written back out and read again")
        XCTAssertEqual(untouched.horizonReservationFloorMB, Config().horizonReservationFloorMB,
                       "a field the saved config never mentioned keeps StarCore's default")

        var overridden = try Config.read(fromJsonFilename: file.path)
        try StarCli.parse(["--merge-streaming-threshold-mb", "0",
                           "--ignore-lower-pixels", "42",
                           "--no-skip-output-files",
                           file.path]).configOverrides.apply(to: &overridden)
        XCTAssertEqual(overridden.mergeStreamingThresholdMB, 0)
        XCTAssertEqual(overridden.ignoreLowerPixels, 42)
        XCTAssertTrue(overridden.writeOutputFiles,
                      "a config saved with -s has to be renderable again")
        XCTAssertEqual(overridden.alignmentKeypointDetectionDivisor, 2.0,
                      "still untouched by a command line that did not mention it")
    }

    // MARK: - nothing falls out of the wiring

    /// Catches the next version of this bug at its source: a field added to
    /// `ConfigOverrides` but never hooked up to a flag stays nil even when every flag is
    /// passed, so it could never override anything.
    func testEveryOverrideIsWiredToAFlag() throws {
        let overrides = try StarCli.parse(Self.everyFlag).configOverrides
        let fields = Mirror(reflecting: overrides).children

        XCTAssertGreaterThanOrEqual(fields.count, 14,
                                    "only found \(fields.count) overrides; if the struct "
                                    + "shrank, the tests above are checking less than "
                                    + "they look like they are")
        for field in fields {
            XCTAssertFalse(isNil(field.value),
                           "\(field.label ?? "?") is nil with every flag on the command "
                           + "line, so no flag feeds it")
        }
    }

    /// And the mirror image: nothing may invent a value the user did not ask for.
    func testNoOverrideAppearsWithoutAFlag() throws {
        let overrides = try StarCli.parse(["/some/star_temp_seq/config.json"]).configOverrides
        for field in Mirror(reflecting: overrides).children {
            XCTAssertTrue(isNil(field.value),
                          "\(field.label ?? "?") has a value from a bare command line, so "
                          + "it will overwrite whatever the saved config holds")
        }
    }

    /// `--last-frame` is deliberately not an override: it limits one run rather than
    /// describing the sequence, so it must not reach the `Config` that gets saved, where
    /// no `--no-` form could ever clear it again.  See `LastFrameTests` for the wiring it
    /// does have.
    func testTheLastFrameFlagIsNotAConfigOverride() throws {
        let cli = try StarCli.parse(["--last-frame", "9", "/some/star_temp_seq/config.json"])
        XCTAssertEqual(cli.lastFrameIndex, 9, "the flag itself parsed")

        for field in Mirror(reflecting: cli.configOverrides).children {
            XCTAssertTrue(isNil(field.value),
                          "\(field.label ?? "?") has a value from a command line whose only "
                          + "flag was --last-frame")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var c = savedConfig()
        let before = try encoder.encode(c)
        cli.configOverrides.apply(to: &c)
        XCTAssertEqual(try encoder.encode(c), before,
                       "--last-frame changed a config field; it would then be written back "
                       + "into config.json and cap every later resume")
    }

    private func isNil(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return false }
        return mirror.children.isEmpty
    }

    // MARK: - both branches, checked where they are written

    // `run()` needs a real image sequence or a real saved config on disk and then
    // processes it, so which branch applies what is checked as the syntactic property it
    // is. The bug was one branch of an if/else quietly doing less than the other; what
    // has to hold is that neither branch touches a Config field on its own.

    private func cliSource(named filename: String) throws -> String {
        // cli/Tests/starTests/ConfigOverridesTests.swift -> cli/Sources/star/<filename>
        let cliDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = cliDir.appendingPathComponent("Sources/star").appendingPathComponent(filename)
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func starCliSource() throws -> String {
        let source = try cliSource(named: "StarCli.swift")
        XCTAssertTrue(source.contains("struct StarCli"), "did not find StarCli.swift itself")
        return source
    }

    private func offsets(of needle: String, in source: String) -> [Int] {
        var found: [Int] = []
        var searchFrom = source.startIndex
        while let range = source.range(of: needle, range: searchFrom..<source.endIndex) {
            found.append(source.distance(from: source.startIndex, to: range.lowerBound))
            searchFrom = range.upperBound
        }
        return found
    }

    private func offset(of needle: String, in source: String) throws -> Int {
        let found = offsets(of: needle, in: source)
        XCTAssertEqual(found.count, 1, "expected exactly one '\(needle)' in StarCli.swift")
        return try XCTUnwrap(found.first)
    }

    func testBothInputPathsApplyTheOverrides() throws {
        let source = try starCliSource()

        let configFileBranch = try offset(of: #"hasSuffix("config.json")"#, in: source)
        let sequenceBranch = try offset(of: "here we are processing a new image sequence",
                                        in: source)
        XCTAssertLessThan(configFileBranch, sequenceBranch)

        let applications = offsets(of: "configOverrides.apply(to: &config)", in: source)
        XCTAssertEqual(applications.count, 2,
                       "expected one application per input path, found \(applications.count)")
        XCTAssertTrue(applications.contains { $0 > configFileBranch && $0 < sequenceBranch },
                      "the saved config path does not apply the command line overrides — "
                      + "this is the original bug")
        XCTAssertTrue(applications.contains { $0 > sequenceBranch },
                      "the image sequence path does not apply the command line overrides")
    }

    /// The invariant that keeps the two paths from drifting apart again: `run()` never
    /// assigns a Config field itself, so a new flag cannot be wired into one branch only.
    func testNoConfigFieldIsAssignedOutsideTheOverrides() throws {
        let source = try starCliSource()
        let assignment = try NSRegularExpression(pattern: #"\bconfig\.\w+\s*=[^=]"#)
        let all = source as NSString
        let matches = assignment.matches(in: source,
                                         range: NSRange(location: 0, length: all.length))
            .map { all.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(matches, [],
                       "StarCli assigns Config fields directly: \(matches). Every one of "
                       + "those is applied on whichever input path it happens to sit in; "
                       + "put it in ConfigOverrides so both paths get it")
    }

    /// `--log-op-memory` sets a StarCore global rather than a config field, so it needs
    /// its own guard: it has to be set before the branch, not inside one of them.
    func testLogOpMemoryIsAppliedBeforeEitherInputPath() throws {
        let source = try starCliSource()
        let applied = try offset(of: "logOperationMemory = logOpMemory", in: source)
        let branch = try offset(of: "if var inputImageSequenceDirname = imageSequenceDirname",
                                in: source)
        XCTAssertLessThan(applied, branch,
                          "--log-op-memory has to be applied ahead of the input paths, or "
                          + "it works on one of them and silently does nothing on the other")
    }
}
