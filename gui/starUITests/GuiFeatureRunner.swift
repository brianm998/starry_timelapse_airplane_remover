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

    /// Polls `condition` until it holds. Real-time waits only, never a fixed sleep.
    private func waitFor(_ what: String, timeout: TimeInterval, detail: () -> String = { "" }, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw RunnerError("timed out after \(Int(timeout))s waiting for \(what) \(detail())") }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: 1)
        }
    }

    // MARK: steps

    /// Copies the sequence into a fresh temp dir (star derives its temp and output paths from the input
    /// directory's name), then launches the app on the copy and waits for the sequence screen.
    private func openSequence() throws {
        let given = try param("sequence")
        let source = given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given)
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
        try tap("startup.removal.start")
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
        // The output goes to <outputPath>/<sequence name>-star-v-<version>, beside the copy we made.
        let fm = FileManager.default
        let siblings = try fm.contentsOfDirectory(atPath: scratch.path)
        let outDirs = siblings.filter { $0.hasPrefix("\(copy.lastPathComponent)-star-v-") }
        guard outDirs.count == 1 else { throw RunnerError("expected one output directory in \(scratch.path), found \(siblings)") }
        let files = try fm.contentsOfDirectory(atPath: scratch.appendingPathComponent(outDirs[0]).path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, want, "frames written to \(outDirs[0]): \(files.sorted())")
        XCTAssertEqual(complete, want, "the left panel's complete count")
    }
}
