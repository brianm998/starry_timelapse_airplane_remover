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
    private var sequenceCopy: URL?
    private var completeFrames: Int?

    init(testCase: XCTestCase) {
        self.testCase = testCase
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-\(UUID().uuidString)")
    }

    // MARK: dispatch table

    static let methodMap: [StepAction: (GuiFeatureRunner) throws -> Void] = [
        .openSequence: { try $0.openSequence() },
        .processEveryFrame: { try $0.processEveryFrame() },
        .outputFramesWritten: { try $0.outputFramesWritten() },
        // The GUI only ever runs Star's default clean method (automatic:false), so this step asserts nothing to set.
        // automatic:true and selective are deliberately absent: a feature that asks for them fails naming what is implemented.
        .cleanMethodAutomaticFalse: { _ in },
        .airplanesRemoved: { try $0.trailsRemoved(trailClass: "airplane") },
        .satellitesRemoved: { try $0.trailsRemoved(trailClass: "satellite") },
        .starsPreserved: { try $0.starsPreserved() },
    ]

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        testCase.continueAfterFailure = false
        defer {
            if app.state != .notRunning { app.terminate() }
            try? FileManager.default.removeItem(at: scratch)
        }
        for step in feature.steps {
            guard let method = Self.methodMap[step.action] else {
                throw RunnerError("no method for step \"\(step.description)\". Implemented steps:\n"
                                  + Self.methodMap.keys.map { "  \($0.rawValue)" }.sorted().joined(separator: "\n"))
            }
            try XCTContext.runActivity(named: step.description) { _ in try method(self) }
        }
    }

    // MARK: placeholders

    private func param(_ name: String) throws -> String {
        // xcodebuild forwards TEST_RUNNER_STAR_GHERKIN_<NAME> to the runner as STAR_GHERKIN_<NAME>.
        guard let v = Params.resolve(name, client: Self.client, environment: ProcessInfo.processInfo.environment) else {
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
    private func waitFor(_ what: String, timeout: TimeInterval, detail: () -> String = { "" }, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw RunnerError("timed out after \(Int(timeout))s waiting for \(what) \(detail())") }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 1)
        }
    }

    /// The test-data cache, by the fetch tool's rule. Under xcodebuild it arrives as `TEST_RUNNER_STAR_TEST_DATA` (prefix stripped);
    /// otherwise `<repoRoot>/.test-data`.
    private func dataCache() -> URL {
        if let c = ProcessInfo.processInfo.environment["STAR_TEST_DATA"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return Self.repoRoot.appendingPathComponent(".test-data")
    }

    // MARK: steps

    /// Copies the sequence into a fresh temp dir (star derives its temp and output paths from the input
    /// directory's name), then launches the app on the copy and waits for the sequence screen.
    private func openSequence() throws {
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

        // A run marker left by an earlier launch would raise the "previous run crashed" critical alert over the window.
        let markers = scratch.appendingPathComponent("run-markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        app.launchArguments += ["-StarUITestOpenSequence", copy.path]
        app.launch()

        // The sequence screen is up once the left panel's progress line is.
        guard element("processing.progress").waitForExistence(timeout: 600) else {
            throw RunnerError("the sequence did not open within 600s\n\(app.debugDescription)")
        }
    }

    /// The startup questions with their defaults (a horizon, a static camera, no hand painted horizon,
    /// remove everything), Start Processing, "render a video afterwards?" No, then wait for the run to finish.
    private func processEveryFrame() throws {
        guard sequenceCopy != nil else { throw RunnerError("\"I open the sequence\" has not run") }
        try tap("startup.horizon.yes")
        try tap("startup.moving.static")
        try tap("startup.selecthorizon.no")
        try activateDefault("startup.removal.start")
        // A user who chose "don't ask again" skips this prompt; the run is simply already going then.
        if element("prompt.pre.no").waitForExistence(timeout: 30) { element("prompt.pre.no").click() }

        let progress = element("processing.progress")
        var last = "(none)"
        try waitFor("processing to finish", timeout: 45 * 60, detail: { "(last progress: \(last))" }) {
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

    private func outputFramesWritten() throws {
        let expected = try param("expected_outputs")
        guard let want = Int(expected) else { throw RunnerError("{expected_outputs} is not a number: \(expected)") }
        guard let copy = sequenceCopy, let complete = completeFrames else { throw RunnerError("\"I process every frame\" has not run") }
        let outDir = try outputDirectory(copy)
        let files = try FileManager.default.contentsOfDirectory(atPath: outDir.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, want, "frames written to \(outDir.lastPathComponent): \(files.sorted())")
        XCTAssertEqual(complete, want, "the left panel's complete count")
    }

    /// The output goes to <outputPath>/<sequence name>-star-v-<version>, beside the copy we made.
    private func outputDirectory(_ copy: URL) throws -> URL {
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        let outDirs = siblings.filter { $0.hasPrefix("\(copy.lastPathComponent)-star-v-") }
        guard outDirs.count == 1 else { throw RunnerError("expected one output directory in \(scratch.path), found \(siblings)") }
        return scratch.appendingPathComponent(outDirs[0])
    }

    // MARK: removal checks (star-removal-verify)
    // Same verifier, flags and vacuous-green guards as cli/Tests/GherkinTests/CliFeatureRunner.swift. The UI-test runner is not
    // sandboxed (star.entitlements is empty and the target has no sandbox setting), so it can launch the verifier as a subprocess and
    // read the output directory directly.

    private func frameCount(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    private func verifierBinary() throws -> URL {
        let path = ProcessInfo.processInfo.environment["STAR_REMOVAL_VERIFY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.repoRoot.appendingPathComponent("removal_tools/.build/release/star-removal-verify").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError("no star-removal-verify at \(path): run `swift build -c release --package-path removal_tools`, or set TEST_RUNNER_STAR_REMOVAL_VERIFY")
        }
        return URL(fileURLWithPath: path)
    }

    /// Where reports and crops go. Not the scratch directory (deleted when the scenario ends): CI uploads this as an artifact.
    private func reportsDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["STAR_REMOVAL_REPORTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? Self.repoRoot.appendingPathComponent("removal-reports")
        return base.appendingPathComponent("gui-removeAirplanes")
    }

    private func labelsFile() throws -> URL {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let labels = input.appendingPathComponent("labels.json")
        guard FileManager.default.fileExists(atPath: labels.path) else { throw RunnerError("no labels.json in the sequence: \(labels.path)") }
        return labels
    }

    /// Runs the verifier with the GUI's only clean method, automatic:false. A failing exit status fails the step with its summary.
    private func runVerifier(_ extra: [String], reportName: String) throws -> [String: Any] {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        guard completeFrames != nil else { throw RunnerError("\"I process every frame\" has not run") }
        let reports = reportsDirectory()
        let crops = reports.appendingPathComponent("\(reportName)-crops")
        let report = reports.appendingPathComponent("\(reportName).json")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)

        let args = ["--input", input.path, "--output", try outputDirectory(input).path, "--labels", try labelsFile().path,
                    "--thresholds", Self.repoRoot.appendingPathComponent("gherkin/removal-thresholds.json").path,
                    "--clean-method", "automatic:false", "--dataset", input.lastPathComponent,
                    "--skip-unmeasurable", "--report", report.path, "--crops", crops.path] + extra

        let p = Process()
        p.executableURL = try verifierBinary()
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        print(text.split(separator: "\n").suffix(12).joined(separator: "\n"))
        guard p.terminationStatus == 0 else {
            throw RunnerError("star-removal-verify exited \(p.terminationStatus)\n"
                              + text.split(separator: "\n").suffix(30).joined(separator: "\n")
                              + "\nreport: \(report.path)\ncrops: \(crops.path)")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any] else {
            throw RunnerError("unreadable report \(report.path)")
        }
        return json
    }

    private func confirmedObjectCount(trailClass: String) throws -> Int {
        let data = try Data(contentsOf: try labelsFile())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = root["frames"] as? [String: [[String: Any]]] else { throw RunnerError("labels.json is not a label set") }
        return frames.values.joined().filter { ($0["class"] as? String) == trailClass && ($0["confirmed"] as? Bool) == true }.count
    }

    private func trailsRemoved(trailClass: String) throws {
        let expected = try confirmedObjectCount(trailClass: trailClass)
        let report = try runVerifier(["--expect", "\(trailClass)=removed"], reportName: "\(trailClass)s-removed")
        // not vacuous: the verifier must have looked at every confirmed object of this class
        let summary = report["summary"] as? [String: Any]
        let objects = (summary?["objects"] as? Int) ?? -1
        guard expected > 0 else { throw RunnerError("labels.json has no confirmed \(trailClass) objects: the step would check nothing") }
        guard objects == expected else {
            throw RunnerError("the verifier checked \(objects) \(trailClass) objects, labels.json has \(expected) confirmed: refusing to pass")
        }
        let measured = (summary?["passed"] as? Int ?? 0) + (summary?["failed"] as? Int ?? 0)
        guard measured > 0 else { throw RunnerError("no \(trailClass) object was measurable: refusing to pass") }
    }

    private func starsPreserved() throws {
        guard let copy = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let report = try runVerifier(["--stars"], reportName: "stars")
        let frames = frameCount(try outputDirectory(copy))
        let stars = (report["stars"] as? [String: Any])?.count ?? 0
        guard stars == frames, frames > 0 else { throw RunnerError("the star check covered \(stars) frames, Star wrote \(frames): refusing to pass") }
    }
}
