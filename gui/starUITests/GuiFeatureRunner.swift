import Foundation
import StarGherkinKernel
import XCTest

/// Runs a generated `Feature` against the real `Star.app` with XCUITest. The step vocabulary is
/// `StepAction`; every case has to appear in `methodMap` or the run fails naming what is implemented.
///
/// The app is opened on the sequence through its `-StarUITestOpenSequence <dir>` launch argument (the open
/// panel is the only other way in and cannot be driven), and every control a step touches carries an
/// accessibility identifier: `startup.*`, `prompt.pre.no` and `processing.progress`.
@MainActor
final class GuiFeatureRunner {
    struct RunnerError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let client = "mac-gui"

    let testCase: XCTestCase
    private let app = XCUIApplication()
    private let scratch: URL
    private var feature: Feature?
    private var sequenceCopy: URL?             // what the app was opened on: a sequence directory, or a video file
    private var sourceVideo: URL?
    private var inputFrames: URL?              // the frames Star processes (the decoded ones, for a video)
    private var completeFrames: Int?
    private var rendersVideo = false
    private var finishedReview = false
    private var settledOnce = false

    // The setting steps, applied as the startup prompts when the sequence opens (the generator makes them precede the open step).
    private var horizon: Bool?
    private var moving: Bool?
    private var clean: String?                 // auto | selective | autoSelective, the validator's spelling

    init(testCase: XCTestCase) {
        self.testCase = testCase
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-\(UUID().uuidString)")
    }

    // MARK: dispatch table

    static let methodMap: [StepAction: (GuiFeatureRunner) throws -> Void] = [
        .horizonYes: { $0.horizon = true },
        .horizonNo: { $0.horizon = false },
        .cameraStatic: { $0.moving = false },
        .cameraMoving: { $0.moving = true },
        .cleanAuto: { $0.clean = "auto" },
        .cleanSelective: { $0.clean = "selective" },
        .cleanAutoSelective: { $0.clean = "autoSelective" },
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

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        testCase.continueAfterFailure = false
        self.feature = feature
        // The pre-processing prompt asks whether to render afterwards, which is where this client chooses it.
        rendersVideo = feature.steps.contains { $0.action == .renderOutputVideo }
        defer {
            saveArtifacts(of: feature)
            if app.state != .notRunning { app.terminate() }
            try? FileManager.default.removeItem(at: scratch)
        }
        for step in feature.steps {
            guard let method = Self.methodMap[step.action] else {
                throw RunnerError("no method for step \"\(step.description)\". Implemented steps:\n"
                                  + Self.methodMap.keys.map { "  \($0.rawValue)" }.sorted().joined(separator: "\n"))
            }
            try XCTContext.runActivity(named: step.description) { _ in
                do { try method(self) } catch {
                    // said here as well: the cleanup that follows can raise issues of its own and bury this one
                    print("STEP FAILED: \(step.description): \(error)")
                    throw error
                }
            }
        }
    }

    // MARK: placeholders

    private func param(_ name: String) throws -> String {
        // xcodebuild forwards TEST_RUNNER_STAR_GHERKIN_<NAME> to the runner as STAR_GHERKIN_<NAME>.
        guard let v = Params.resolve(name, client: Self.client, feature: feature?.id, environment: ProcessInfo.processInfo.environment) else {
            throw RunnerError("no value for {\(name)}")
        }
        return v
    }

    /// The repository root, from this file's own path: gui/starUITests/GuiFeatureRunner.swift.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: element lookup

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 120) throws {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else {
            throw RunnerError("\(identifier) did not appear within \(Int(timeout))s\n\(app.debugDescription)")
        }
        e.click()
    }

    /// Clicks the element; if it exists but cannot be hit (on a small display the sheet's lower buttons can sit below the
    /// screen's edge, as on hosted runners), presses Return instead, which is that button's default action.
    private func activateDefault(_ identifier: String, timeout: TimeInterval = 120) throws {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else {
            throw RunnerError("\(identifier) did not appear within \(Int(timeout))s\n\(app.debugDescription)")
        }
        if e.isHittable { e.click() } else { app.typeKey(.return, modifierFlags: []) }
    }

    /// Polls `condition` until it holds. Real-time waits only, never a fixed sleep.
    /// `interval`: a busy app (the horizon overlays, previews) can take longer than XCUITest's snapshot timeout to answer, which fails the
    /// test outright, so the long waits poll slowly.
    private func waitFor(_ what: String, timeout: TimeInterval, interval: TimeInterval = 1, detail: () -> String = { "" }, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw RunnerError("timed out after \(Int(timeout))s waiting for \(what) \(detail())") }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: interval)
        }
    }

    /// The test-data cache, by the fetch tool's rule. Under xcodebuild it arrives as `TEST_RUNNER_STAR_TEST_DATA` (prefix stripped);
    /// otherwise `<repoRoot>/.test-data`.
    private func dataCache() -> URL {
        if let c = ProcessInfo.processInfo.environment["STAR_TEST_DATA"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return Self.repoRoot.appendingPathComponent(".test-data")
    }

    // MARK: steps

    private func requireSettings() throws -> (horizon: Bool, moving: Bool, clean: String) {
        guard let h = horizon, let m = moving, let c = clean else {
            throw RunnerError("horizon, camera and clean method steps must all come before the open or import step")
        }
        return (h, m, c)
    }

    /// Launches the app with a fresh run-marker directory: a marker left by an earlier launch would raise the
    /// "previous run crashed" critical alert over the window.
    private func launch(arguments: [String]) throws {
        let markers = scratch.appendingPathComponent("run-markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        // The app keeps its preferences in $HOME/.star.userprefs.json. A test must neither read nor write the real one: a "don't ask me
        // again" answered on this machine once skipped the render prompt and with it the video the feature asked for.
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments += arguments
        app.launch()
    }

    /// Copies the sequence into a fresh temp dir (star derives its temp and output paths from the input
    /// directory's name), then launches the app on the copy and waits for the sequence screen.
    private func openSequence() throws {
        _ = try requireSettings()
        let given = try param("sequence")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError("sequence directory not found: \(source.path)")
        }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        sequenceCopy = copy
        inputFrames = copy
        try launch(arguments: ["-StarUITestOpenSequence", copy.path])
        try answerStartupPrompts()
    }

    /// Opens the video through the import sheet (`-StarUITestOpenVideo` raises it as the open panel would), choosing the
    /// frame format the feature asks for.
    private func importVideo() throws {
        _ = try requireSettings()
        let given = try param("video")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
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
        inputFrames = scratch.appendingPathComponent(copy.deletingPathExtension().lastPathComponent)
        try launch(arguments: ["-StarUITestOpenVideo", copy.path])

        let format = try param("frame_format").lowercased()
        let formats = ["tiff16", "tiff8", "jpeg"]
        guard let index = formats.firstIndex(of: format) else { throw RunnerError("{frame_format} must be one of \(formats), not \(format)") }
        guard element("videoimport.import").waitForExistence(timeout: 120) else {
            throw RunnerError("the video import sheet did not appear\n\(app.debugDescription)")
        }
        // A radio group's items do not always expose the identifier of the Text they were made from, so fall back to position.
        let radio = element("videoimport.format.\(format)")
        if radio.exists { radio.click() } else { app.radioGroups.firstMatch.radioButtons.element(boundBy: index).click() }
        try tap("videoimport.import")
        try answerStartupPrompts()
    }

    /// Horizon → camera → (select horizon: No) → what to remove → Start, as a user answers them.
    private func answerStartupPrompts() throws {
        let s = try requireSettings()
        // The sequence screen is up once the first startup question is (decoding a video comes first).
        try tap(s.horizon ? "startup.horizon.yes" : "startup.horizon.no", timeout: 600)
        try tap(s.moving ? "startup.moving.moving" : "startup.moving.static")
        if s.horizon { try tap(s.moving ? "startup.selectmovinghorizons.no" : "startup.selecthorizon.no") }

        // Removal toggles, all on by default: everything is automatic; meteors off is auto selective; satellites off is selective.
        guard element("startup.removal.start").waitForExistence(timeout: 120) else { throw RunnerError("the removal prompt did not appear") }
        switch s.clean {
        case "auto": break
        case "autoSelective": try tap("startup.removal.meteors")
        case "selective": try tap("startup.removal.satellites")
        default: throw RunnerError("unknown clean method \(s.clean)")
        }
    }

    /// Start Processing, "render a video afterwards?" per the feature, then wait for the run (and the render) to finish.
    private func processEveryFrame() throws {
        guard sequenceCopy != nil else { throw RunnerError("neither \"I open the sequence\" nor \"I import the video\" has run") }
        try activateDefault("startup.removal.start")
        // A user who chose "don't ask again" skips this prompt; the run is simply already going then.
        let prompt = rendersVideo ? "prompt.pre.yes" : "prompt.pre.no"
        if element(prompt).waitForExistence(timeout: 30) { element(prompt).click() }

        // XCUITest queries are answered by the app's own main thread, which is the thread the horizon overlays and previews keep busy:
        // measured, the runner's polling was about half of it, and a query that waits too long fails the test. So the long waits watch the
        // disk, and the UI is asked once the disk says the run is over. Auto selective has no such file to watch (its frames wait for
        // review), so it asks the UI, slowly.
        let expected = try frameFiles(in: inputFrames).count
        if clean == "autoSelective" { try finishAutoSelective(expected: expected); return }

        let progress = element("processing.progress")
        var last = "(none)"
        try waitFor("processing to finish", timeout: 45 * 60, interval: 5, detail: { "(last progress: \(last))" }) {
            guard let out = try? outputFrames(), ((try? frameFiles(in: out).count) ?? 0) >= expected else { return false }
            // With a render afterwards the render sheet covers the window the moment the run ends, and the progress line is no longer in
            // reach: the frames all being on disk (and still so a poll later) is the end of processing.
            if rendersVideo {
                defer { settledOnce = true }
                if settledOnce { completeFrames = expected }
                return settledOnce
            }
            guard progress.exists else { return false }
            let state = progress.label
            if state != last { print("progress: \(state)") }
            last = state
            let parts = state.split(separator: "/").map(String.init)
            guard parts.count == 3, let complete = Int(parts[0]), let total = Int(parts[1]) else { return false }
            let done = total > 0 && complete == total && parts[2] == "idle"
            if done { completeFrames = complete }
            return done
        }
    }

    /// Auto selective leaves every frame waiting for its outliers to be reviewed (run over, not all complete): the user finishes by
    /// rendering all frames, which writes the finals without moving the complete count. The cli has no review, so it writes them itself.
    /// The run is watched on the disk (its outlier data, then the finals): XCUITest queries are answered by a busy app's main thread.
    private func finishAutoSelective(expected: Int) throws {
        func tempDir() -> URL? {
            (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.first { $0.hasPrefix("star_temp_") }
                .map { scratch.appendingPathComponent($0) }
        }
        try waitFor("every frame's outlier data", timeout: 45 * 60, interval: 10) {
            guard let t = tempDir() else { return false }
            return ((try? frameFiles(in: t.appendingPathComponent("auto-selective-processed")).count) ?? 0) >= expected
        }
        // The button is there but dead until the run is over: click it once it can be.
        let render = element("render.all.frames")
        try waitFor("Render All Frames to be enabled", timeout: 10 * 60, interval: 10) { render.exists && render.isEnabled }
        render.click()
        try waitFor("the final frames", timeout: 30 * 60, interval: 10) {
            guard let out = try? outputFrames() else { return false }
            return ((try? frameFiles(in: out).count) ?? 0) >= expected
        }
        // let the last frame's write land
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 5)
        completeFrames = expected
    }

    private func frameFiles(in dir: URL?) throws -> [String] {
        guard let dir else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            !$0.hasPrefix(".") && ["tif", "tiff", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// The video's path, once the render has written it: `<outputPath>/<name>.<container>`, beside the output frames.
    private func renderedVideoFile() throws -> URL? {
        let base = try outputFrames().lastPathComponent
        return try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .first { $0.hasPrefix(base) && ["mov", "mp4", "mkv", "avi"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { scratch.appendingPathComponent($0) }
    }

    /// Processing answered Yes to the render prompt, so the render sheet opens and starts by itself with the default settings.
    /// Watched on the disk, like processing: the video exists and has stopped growing.
    private func renderOutputVideoStep() throws {
        guard rendersVideo else { throw RunnerError("the render prompt was answered No") }
        var lastSize = -1
        do {
            try waitFor("the video render to finish", timeout: 10 * 60, interval: 5) {
                guard let video = try? renderedVideoFile(),
                      let size = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int, size > 0 else { return false }
                defer { lastSize = size }
                return size == lastSize
            }
        } catch {
            // The screenshot is the only evidence of what the sheet was showing.
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            testCase.add(shot)
            throw error
        }
    }

    /// Copies the validator's reports and the run's config.json to `$STAR_GHERKIN_ARTIFACTS/<feature>` for CI to upload.
    private func saveArtifacts(of feature: Feature) {
        // Default: the runner's own container tmp (`~/Library/Containers/com.star-guiUITests.xctrunner/Data/tmp/gherkin-artifacts`), the only
        // place a sandboxed runner can write; CI uploads that directory.
        let dir = ProcessInfo.processInfo.environment["STAR_GHERKIN_ARTIFACTS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("gherkin-artifacts")
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(feature.id)
        // The UI-test runner is sandboxed: it can only write inside its own container, so a directory outside it is skipped, not failed.
        // (CI uploads the container's tmp directory instead; see the workflow.)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { print("artifacts: cannot write \(dest.path): \(error)"); return }
        for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] {
            if name.hasPrefix("report-") { if fm.fileExists(atPath: dest.appendingPathComponent(name).path) { try? fm.removeItem(at: dest.appendingPathComponent(name)) }; try? fm.copyItem(at: scratch.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
            if name.hasPrefix("star_temp_"), fm.fileExists(atPath: scratch.appendingPathComponent(name).appendingPathComponent("config.json").path) {
                if fm.fileExists(atPath: dest.appendingPathComponent("config.json").path) { try? fm.removeItem(at: dest.appendingPathComponent("config.json")) }
                try? fm.copyItem(at: scratch.appendingPathComponent(name).appendingPathComponent("config.json"), to: dest.appendingPathComponent("config.json"))
            }
        }
    }

    // MARK: validation: removal_tools/star-output-verify, the one tool every client uses

    private func verifyBinary() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["STAR_OUTPUT_VERIFY_PATH"], !p.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: p) else { throw RunnerError("STAR_OUTPUT_VERIFY_PATH is not an executable: \(p)") }
            return URL(fileURLWithPath: p)
        }
        let exe = Self.repoRoot.appendingPathComponent("removal_tools/.build/release/star-output-verify")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw RunnerError("no validator at \(exe.path): run `swift build -c release --package-path removal_tools`, or set STAR_OUTPUT_VERIFY_PATH")
        }
        return exe
    }

    private func verify(_ args: [String]) throws {
        let p = Process()
        p.executableURL = try verifyBinary()
        p.arguments = args + ["--report", scratch.appendingPathComponent("report-\(args[0]).json").path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")
        print(lines.count > 40 ? (lines.prefix(10) + ["…"] + lines.suffix(10)).joined(separator: "\n") : text)
        guard p.terminationStatus == 0 else { throw RunnerError("star-output-verify \(args[0]) failed:\n\(text)") }
    }

    /// The directory processing wrote the final frames to: `<outputPath>/<sequence name>-star-v-<version>`, beside the copy.
    private func outputFrames() throws -> URL {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        // directories only: the rendered video is a sibling with the same prefix
        let outDirs = siblings.filter {
            var isDir: ObjCBool = false
            return $0.hasPrefix("\(input.lastPathComponent)-star-v-")
              && FileManager.default.fileExists(atPath: scratch.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        }
        guard outDirs.count == 1 else { throw RunnerError("expected one output directory in \(scratch.path), found \(siblings)") }
        return scratch.appendingPathComponent(outDirs[0])
    }

    /// The run's saved config.json: in the `star_temp_<name>` directory beside the input, as for the cli.
    private func configJSON() throws -> URL {
        let found = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix("star_temp_") }
            .map { scratch.appendingPathComponent($0).appendingPathComponent("config.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard found.count == 1 else { throw RunnerError("expected one star_temp_*/config.json in \(scratch.path), found \(found.map(\.path))") }
        return found[0]
    }

    private func usedRequestedSettings() throws {
        let s = try requireSettings()
        try verify(["settings", "--config", try configJSON().path, "--horizon", s.horizon ? "yes" : "no",
                    "--camera", s.moving ? "moving" : "static", "--clean", s.clean])
    }

    private func everyFrameOutput() throws {
        guard let input = inputFrames, completeFrames != nil else { throw RunnerError("\"I process every frame\" has not run") }
        var args = ["frames", "--input-dir", input.path, "--output-dir", try outputFrames().path]
        if let v = sourceVideo { args += ["--video", v.path] }
        try verify(args)
    }

    private func outputKeepsFormat() throws {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        try verify(["format", "--input-dir", input.path, "--output-dir", try outputFrames().path])
    }

    private func processedIn(_ mode: String) throws {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        var args = ["mode", "--mode", mode, "--input-dir", input.path, "--output-dir", try outputFrames().path,
                    "--thresholds", Self.repoRoot.appendingPathComponent("removal_tools/thresholds.json").path]
        if mode == "autoSelective" { args += ["--config", try configJSON().path] }
        if ProcessInfo.processInfo.environment["STAR_GHERKIN_REPORT_ONLY"] != nil { args.append("--report-only") }
        try verify(args)
    }

    private func outputVideoMatches() throws {
        // The video is written beside the output frames, as `<outputPath>/<name>.<container>`, in the imported video's
        // settings, else Config's defaults (ProRes, 30 fps).
        let frames = try outputFrames()
        let base = frames.lastPathComponent
        let candidates = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter {
            $0.hasPrefix(base) && ["mov", "mp4", "mkv", "avi"].contains(($0 as NSString).pathExtension.lowercased())
        }
        guard candidates.count == 1 else { throw RunnerError("expected one rendered video named \(base).* in \(scratch.path), found \(candidates)") }
        try verify(["video", "--video", scratch.appendingPathComponent(candidates[0]).path, "--output-dir", frames.path,
                    "--frame-rate", "30/1", "--codec", sourceVideo == nil ? "prores" : "h264"])
    }

    /// Star's critical warnings are alerts: none may be on screen at the end.
    private func noProblems() throws {
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert is on screen: \(app.alerts.firstMatch.debugDescription)")
    }
}
