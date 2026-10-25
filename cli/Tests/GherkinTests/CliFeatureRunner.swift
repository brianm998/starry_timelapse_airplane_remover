import Foundation
import StarGherkinKernel
import XCTest

/// Runs a generated `Feature` against the built `star` binary as a subprocess. Black-box: this target
/// does not import `star`, StarCore or StarDecisionTrees. The step vocabulary is `StepAction`; every
/// case has to appear in `methodMap` or the run fails naming what is implemented.
final class CliFeatureRunner {
    struct RunnerError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let client = "cli"

    /// The settings the setup steps ask for; applied when the sequence is opened or imported (see `GherkinTests` ordering rule).
    struct Settings {
        var horizon: Bool?
        var moving: Bool?
        var clean: String?      // auto | selective | autoSelective, the validator's spelling
    }

    let testCase: XCTestCase
    private var feature: Feature?
    private var settings = Settings()
    private(set) var sequenceCopy: URL?          // what star was given: a sequence directory, or a video file
    private var sourceVideo: URL?
    private var inputFramesDir: URL?             // the frames star processes (the decoded frames, for a video)
    private(set) var outputDir: URL?
    private var rendersVideo = false
    private var renderedVideo: String?
    private var runLog = ""
    private var tempDir: URL?
    private let scratch: URL

    init(testCase: XCTestCase) {
        self.testCase = testCase
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-\(UUID().uuidString)")
    }

    // MARK: dispatch table

    // Computed, not stored: a stored dictionary of closures is not concurrency-safe in Swift 6 mode.
    static var methodMap: [StepAction: (CliFeatureRunner) throws -> Void] {
        [
            .horizonYes: { $0.settings.horizon = true },
            .horizonNo: { $0.settings.horizon = false },
            .cameraStatic: { $0.settings.moving = false },
            .cameraMoving: { $0.settings.moving = true },
            .cleanAuto: { $0.settings.clean = "auto" },
            .cleanSelective: { $0.settings.clean = "selective" },
            .cleanAutoSelective: { $0.settings.clean = "autoSelective" },
            .openSequence: { try $0.openSequence() },
            .importVideo: { try $0.importVideo() },
            .processEveryFrame: { try $0.processEveryFrame() },
            .renderOutputVideo: { try $0.renderOutputVideoStep() },
            .usedRequestedSettings: { try $0.usedRequestedSettings() },
            .everyFrameOutput: { try $0.everyFrameOutput() },
            .outputKeepsFormat: { try $0.outputKeepsFormat() },
            .processedAuto: { try $0.processedIn("auto") },
            .processedSelective: { try $0.processedIn("selective") },
            .processedAutoSelective: { try $0.processedIn("autoSelective") },
            .outputVideoMatches: { try $0.outputVideoMatches() },
            .noProblems: { try $0.noProblems() },
        ]
    }

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        // Kept when STAR_GHERKIN_KEEP_SCRATCH is set, so a failure can be looked at.
        defer { if ProcessInfo.processInfo.environment["STAR_GHERKIN_KEEP_SCRATCH"] == nil { try? FileManager.default.removeItem(at: scratch) } else { print("scratch kept: \(scratch.path)") } }
        defer { saveArtifacts(of: feature) }
        self.feature = feature
        // The cli renders as part of the run (`--render-video`), so it has to know before `I process every frame`.
        rendersVideo = feature.steps.contains { $0.action == .renderOutputVideo }
        for step in feature.steps {
            guard let method = Self.methodMap[step.action] else {
                throw RunnerError("no method for step \"\(step.description)\". Implemented steps:\n"
                                  + Self.methodMap.keys.map { "  \($0.rawValue)" }.sorted().joined(separator: "\n"))
            }
            try activity(step.description) { try method(self) }
        }
    }

    /// Reports the step by name. Not XCTContext.runActivity: it is main-actor isolated, which would force the test class onto
    /// the main actor, and SwiftPM's generated Linux test discovery cannot call a main-actor test method.
    private func activity(_ name: String, _ body: () throws -> Void) throws {
        print("STEP: \(name)")
        try body()
    }

    // MARK: placeholders

    private func param(_ name: String) throws -> String {
        guard let v = Params.resolve(name, client: Self.client, feature: feature?.id, environment: ProcessInfo.processInfo.environment) else {
            throw RunnerError("no value for {\(name)}")
        }
        return v
    }

    /// The repository root, from this file's own path: cli/Tests/GherkinTests/CliFeatureRunner.swift.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The test-data cache, by the fetch tool's rule: `STAR_TEST_DATA`, else `<repoRoot>/.test-data`.
    private func dataCache() -> URL {
        if let c = ProcessInfo.processInfo.environment["STAR_TEST_DATA"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return Self.repoRoot.appendingPathComponent(".test-data")
    }

    /// POSIX `/…`, or on Windows a drive letter (`C:\…`, `C:/…`) or a UNC / rooted path (`\\…`).
    static func isAbsolutePath(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        if path.hasPrefix("\\") { return true }
        let chars = Array(path)
        if chars.count >= 3, chars[0].isLetter, chars[1] == ":", chars[2] == "\\" || chars[2] == "/" { return true }
        #endif
        return false
    }

    // MARK: steps

    /// Copies the sequence into a fresh temp dir: star derives its temp and output paths from the
    /// input directory's name, so processing a directory in place would pick up the last run's state.
    private func openSequence() throws {
        let given = try param("sequence")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (Self.isAbsolutePath(given) ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError("sequence directory not found: \(source.path)")
        }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        sequenceCopy = copy
        inputFramesDir = copy
    }

    /// The video inside a `data:` dataset directory (or the file itself), copied into the scratch directory: star decodes next
    /// to the video and derives its temp paths from the name, so it must not touch the cache.
    private func importVideo() throws {
        let given = try param("video")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (Self.isAbsolutePath(given) ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw RunnerError("video not found: \(source.path)") }
        let file: URL
        if isDir.boolValue {
            let videos = try FileManager.default.contentsOfDirectory(atPath: source.path).filter {
                ["mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg"].contains(($0 as NSString).pathExtension.lowercased())
            }
            guard videos.count == 1 else { throw RunnerError("expected exactly one video in \(source.path), found \(videos)") }
            file = source.appendingPathComponent(videos[0])
        } else {
            file = source
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        sequenceCopy = copy
        sourceVideo = copy
        // decodeVideo writes <video dir>/<name>/image_%04d.<ext>
        inputFramesDir = scratch.appendingPathComponent(copy.deletingPathExtension().lastPathComponent)
    }

    private func requireSettings() throws -> (horizon: Bool, moving: Bool, clean: String) {
        guard let h = settings.horizon, let m = settings.moving, let c = settings.clean else {
            throw RunnerError("horizon, camera and clean method steps must all come before the open or import step")
        }
        return (h, m, c)
    }

    private func processEveryFrame() throws {
        guard let input = sequenceCopy else { throw RunnerError("neither \"I open the sequence\" nor \"I import the video\" has run") }
        let s = try requireSettings()
        if inputFramesDir == nil { inputFramesDir = input }
        let out = scratch.appendingPathComponent("output")
        let log = scratch.appendingPathComponent("star.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        // --keep-temp-files: the validator reads the run's config.json and outlier data from the temp directory.
        var args = ["--language", "en", "-l", "info", "--keep-temp-files"]
        if !s.horizon { args.append("--no-horizon") }
        if s.moving { args.append("--moving-camera") }
        args += ["-c", ["auto": "automatic", "selective": "selective", "autoSelective": "automatic:true"][s.clean]!]
        if sourceVideo != nil { args += ["--frame-format", try param("frame_format")] }
        if rendersVideo { args.append("--render-video") }
        args += [input.path, out.path]

        let p = Process()
        p.executableURL = try starBinary()
        p.arguments = args
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        p.waitUntilExit()
        try? logHandle.close()

        runLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(runLog.split(whereSeparator: \.isNewline).suffix(15).joined(separator: "\n"))
        guard p.terminationStatus == 0 else {
            throw RunnerError("star exited \(p.terminationStatus); last output:\n" + runLog.split(whereSeparator: \.isNewline).suffix(40).joined(separator: "\n"))
        }
        outputDir = out
        // star_temp_<sequence name> beside the input: the run's config.json lives there.
        let parent = input.deletingLastPathComponent()
        tempDir = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .first { $0.hasPrefix("star_temp_") }.map { parent.appendingPathComponent($0) }
        renderedVideo = runLog.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Rendered video: ") }
            .map { String($0.dropFirst("Rendered video: ".count)) }
    }

    private func renderOutputVideoStep() throws {
        // `--render-video` ran with the processing (see run()); this checks it happened.
        // The path star printed, else the video beside the input: a log that came back empty must not hide a video that was written.
        if renderedVideo == nil || !FileManager.default.fileExists(atPath: renderedVideo!) {
            let found = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.first {
                $0.contains("-star-v-") && ["mov", "mp4", "mkv", "avi"].contains(($0 as NSString).pathExtension.lowercased())
            }
            renderedVideo = found.map { scratch.appendingPathComponent($0).path } ?? renderedVideo
        }
        guard let video = renderedVideo, FileManager.default.fileExists(atPath: video) else {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.sorted().joined(separator: ", ") ?? "?"
            throw RunnerError("star did not report a rendered video and none is in \(scratch.path) (\(listing)); its log was \(runLog.count) characters; last output:\n"
                              + runLog.split(whereSeparator: \.isNewline).suffix(20).joined(separator: "\n"))
        }
    }

    /// Copies the validator's reports, star's log and the run's config.json to `$STAR_GHERKIN_ARTIFACTS/<feature>` for CI to upload.
    private func saveArtifacts(of feature: Feature) {
        guard let dir = ProcessInfo.processInfo.environment["STAR_GHERKIN_ARTIFACTS"], !dir.isEmpty else { return }
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(feature.id)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] where name.hasPrefix("report-") || name == "star.log" {
            try? fm.copyItem(at: scratch.appendingPathComponent(name), to: dest.appendingPathComponent(name))
        }
        if let temp = tempDir { try? fm.copyItem(at: temp.appendingPathComponent("config.json"), to: dest.appendingPathComponent("config.json")) }
    }

    // MARK: validation (star-output-verify)

    private func verify(_ args: [String]) throws {
        let exe = try verifyBinary()
        let p = Process()
        p.executableURL = exe
        p.arguments = args + ["--report", scratch.appendingPathComponent("report-\(args[0]).json").path]
        var env = ProcessInfo.processInfo.environment
        if env["STAR_FFMPEG_DIR"] == nil, let dir = ToolDirectory.guess { env["STAR_FFMPEG_DIR"] = dir }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        print(lines.count > 40 ? (lines.prefix(10) + ["…"] + lines.suffix(10)).joined(separator: "\n") : text)
        guard p.terminationStatus == 0 else { throw RunnerError("star-output-verify \(args[0]) failed:\n\(text)") }
    }

    private func usedRequestedSettings() throws {
        let s = try requireSettings()
        guard let temp = tempDir else { throw RunnerError("no star_temp_* directory beside the input: \"I process every frame\" has not run") }
        try verify(["settings", "--config", temp.appendingPathComponent("config.json").path,
                    "--horizon", s.horizon ? "yes" : "no", "--camera", s.moving ? "moving" : "static", "--clean", s.clean])
    }

    private func dirs() throws -> (input: String, output: String) {
        guard let i = inputFramesDir, let o = outputDir else { throw RunnerError("\"I process every frame\" has not run") }
        return (i.path, o.path)
    }

    private func everyFrameOutput() throws {
        let d = try dirs()
        var args = ["frames", "--input-dir", d.input, "--output-dir", d.output]
        if let v = sourceVideo { args += ["--video", v.path] }
        try verify(args)
    }

    private func outputKeepsFormat() throws {
        let d = try dirs()
        try verify(["format", "--input-dir", d.input, "--output-dir", d.output])
    }

    private func processedIn(_ mode: String) throws {
        let d = try dirs()
        var args = ["mode", "--mode", mode, "--input-dir", d.input, "--output-dir", d.output,
                    "--thresholds", Self.repoRoot.appendingPathComponent("removal_tools/thresholds.json").path]
        if let t = tempDir { args += ["--temp-dir", t.path] }
        if ProcessInfo.processInfo.environment["STAR_GHERKIN_REPORT_ONLY"] != nil { args.append("--report-only") }
        try verify(args)
    }

    private func outputVideoMatches() throws {
        let d = try dirs()
        guard let video = renderedVideo else { throw RunnerError("no rendered video") }
        // the imported video's settings, else Config's defaults (ProRes, 30 fps)
        var args = ["video", "--video", video, "--output-dir", d.output, "--frame-rate", "30/1"]
        if sourceVideo == nil { args += ["--codec", "prores"] } else { args += ["--codec", "h264"] }
        try verify(args)
    }

    /// Exit 0 was already required by `processEveryFrame`.  The warnings star shows its user are the lines beginning with
    /// the warning sign and two spaces; detector chatter logged at `warn` level (`⚠️ WARN`) is not one of them.
    private func noProblems() throws {
        let warnings = runLog.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("⚠️  ") }
        XCTAssertTrue(warnings.isEmpty, "star reported \(warnings.count) warning(s):\n" + warnings.prefix(10).joined(separator: "\n"))
    }

    /// The validator, built from `removal_tools` (`swift build -c release --package-path removal_tools`), or `STAR_OUTPUT_VERIFY_PATH`.
    private func verifyBinary() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["STAR_OUTPUT_VERIFY_PATH"], !p.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: p) else { throw RunnerError("STAR_OUTPUT_VERIFY_PATH is not an executable: \(p)") }
            return URL(fileURLWithPath: p)
        }
        #if os(Windows)
        let name = "star-output-verify.exe"
        #else
        let name = "star-output-verify"
        #endif
        let exe = Self.repoRoot.appendingPathComponent("removal_tools/.build/release/\(name)")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw RunnerError("no validator at \(exe.path): run `swift build -c release --package-path removal_tools`, or set STAR_OUTPUT_VERIFY_PATH")
        }
        return exe
    }

    // MARK: the binary

    /// `STAR_CLI_PATH`, else the `star` (`star.exe` on Windows) beside the test bundle (SwiftPM builds both into one products directory).
    private func starBinary() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["STAR_CLI_PATH"], !p.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: p) else { throw RunnerError("STAR_CLI_PATH is not an executable: \(p)") }
            return URL(fileURLWithPath: p)
        }
        #if os(macOS)
        guard let bundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) else {
            throw RunnerError("cannot find the .xctest bundle to locate the products directory")
        }
        let products = bundle.bundleURL.deletingLastPathComponent()
        #else
        // Linux: the test runner is `<products>/starPackageTests.xctest`, an executable file, so its bundleURL can be the file
        // itself or the directory holding it depending on the platform: take the directory either way.
        var products = Bundle.main.bundleURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: products.path, isDirectory: &isDir), !isDir.boolValue {
            products = products.deletingLastPathComponent()
        }
        #endif
        #if os(Windows)
        let star = products.appendingPathComponent("star.exe")
        #else
        let star = products.appendingPathComponent("star")
        #endif
        guard FileManager.default.isExecutableFile(atPath: star.path) else {
            throw RunnerError("no star binary at \(star.path): run `swift build` first, or set STAR_CLI_PATH")
        }
        return star
    }
}

/// Where ffmpeg and ffprobe live when `STAR_FFMPEG_DIR` is not set: the same `external_binaries/bin` star itself finds.
enum ToolDirectory {
    static var guess: String? {
        let dir = CliFeatureRunner.repoRoot.appendingPathComponent("external_binaries/bin").path
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }
}
