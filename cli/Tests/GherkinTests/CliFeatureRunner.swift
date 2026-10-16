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

    let testCase: XCTestCase
    private(set) var sequenceCopy: URL?
    private(set) var outputDir: URL?
    private(set) var cleanMethod: String?
    private var featureName = "feature"
    private let scratch: URL

    init(testCase: XCTestCase) {
        self.testCase = testCase
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-\(UUID().uuidString)")
    }

    // MARK: dispatch table

    // Computed, not stored: a stored dictionary of closures is not concurrency-safe in Swift 6 mode.
    static var methodMap: [StepAction: (CliFeatureRunner) throws -> Void] {
        [
            .openSequence: { try $0.openSequence() },
            .processEveryFrame: { try $0.processEveryFrame() },
            .outputFramesWritten: { try $0.outputFramesWritten() },
            .openSequence16: { try $0.openSequence(placeholder: "sequence16") },
            .cleanMethodAutomaticFalse: { $0.cleanMethod = "automatic:false" },
            .cleanMethodAutomaticTrue: { $0.cleanMethod = "automatic:true" },
            .cleanMethodSelective: { $0.cleanMethod = "selective" },
            .airplanesRemoved: { try $0.trailsRemoved(trailClass: "airplane") },
            .satellitesRemoved: { try $0.trailsRemoved(trailClass: "satellite") },
            .starsPreserved: { try $0.starsPreserved() },
        ]
    }

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        defer { try? FileManager.default.removeItem(at: scratch) }
        featureName = feature.name
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
        guard let v = Params.resolve(name, client: Self.client, environment: ProcessInfo.processInfo.environment) else {
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

    // MARK: steps

    /// Copies the sequence into a fresh temp dir: star derives its temp and output paths from the
    /// input directory's name, so processing a directory in place would pick up the last run's state.
    private func openSequence() throws { try openSequence(placeholder: "sequence") }

    private func openSequence(placeholder: String) throws {
        let given = try param(placeholder)
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
    }

    private func processEveryFrame() throws {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let out = scratch.appendingPathComponent("output")
        let log = scratch.appendingPathComponent("star.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        let p = Process()
        p.executableURL = try starBinary()
        var args = ["-l", "info"]
        if let m = cleanMethod { args += ["-c", m] }
        p.arguments = args + [input.path, out.path]
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        p.waitUntilExit()
        try? logHandle.close()

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        print(text.split(separator: "\n").suffix(15).joined(separator: "\n"))
        guard p.terminationStatus == 0 else {
            throw RunnerError("star exited \(p.terminationStatus); last output:\n" + text.split(separator: "\n").suffix(40).joined(separator: "\n"))
        }
        outputDir = out
    }

    private func outputFramesWritten() throws {
        let expected = try param("expected_outputs")
        guard let want = Int(expected) else { throw RunnerError("{expected_outputs} is not a number: \(expected)") }
        guard let out = outputDir else { throw RunnerError("\"I process every frame\" has not run") }
        let files = (try FileManager.default.contentsOfDirectory(atPath: out.path)).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(files.count, want, "frames written to \(out.path): \(files.sorted())")
    }

    // MARK: removal checks (star-removal-verify)

    /// The directory Star's frames are in: the output directory itself, or the single `*star-v-*` directory inside it.
    private func framesDirectory(_ out: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        if let sub = entries.first(where: { $0.contains("star-v-") }) { return out.appendingPathComponent(sub) }
        return out
    }

    /// Where reports and crops go. Not the scratch directory (deleted when the scenario ends): CI uploads this as an artifact.
    private func reportsDirectory() -> URL {
        let base = ProcessInfo.processInfo.environment["STAR_REMOVAL_REPORTS"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? Self.repoRoot.appendingPathComponent("removal-reports")
        return base.appendingPathComponent(featureName)
    }

    private func verifierBinary() throws -> URL {
        let path = ProcessInfo.processInfo.environment["STAR_REMOVAL_VERIFY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.repoRoot.appendingPathComponent("removal_tools/.build/release/star-removal-verify").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError("no star-removal-verify at \(path): run `swift build -c release --package-path removal_tools`, or set STAR_REMOVAL_VERIFY")
        }
        return URL(fileURLWithPath: path)
    }

    private func labelsFile() throws -> URL {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let labels = input.appendingPathComponent("labels.json")
        guard FileManager.default.fileExists(atPath: labels.path) else { throw RunnerError("no labels.json in the sequence: \(labels.path)") }
        return labels
    }

    /// Runs the verifier. A failing exit status fails the step with its summary and the report and crop paths.
    private func runVerifier(_ extra: [String], reportName: String) throws -> [String: Any] {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        guard let out = outputDir else { throw RunnerError("\"I process every frame\" has not run") }
        let reports = reportsDirectory()
        let crops = reports.appendingPathComponent("\(reportName)-crops")
        let report = reports.appendingPathComponent("\(reportName).json")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let method = cleanMethod ?? "automatic:false"   // star's default clean method

        var args = ["--input", input.path, "--output", try framesDirectory(out).path, "--labels", try labelsFile().path,
                    "--thresholds", Self.repoRoot.appendingPathComponent("gherkin/removal-thresholds.json").path,
                    "--clean-method", method, "--dataset", input.lastPathComponent,
                    "--skip-unmeasurable", "--report", report.path, "--crops", crops.path]
        if method == "automatic:true" {
            // per-object verdicts differ between platforms; the fraction does not (BUGS.md BUG-004). The fraction cannot
            // see the 1b2cb327 bug (0.78 broken vs 0.83 fixed), so the objects both modes agree on are pinned as well.
            args += ["--aggregate", "--pins", Self.repoRoot.appendingPathComponent("gherkin/removal-pins.json").path]
        }
        args += extra

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
            throw RunnerError("star-removal-verify exited \(p.terminationStatus) for \"\(featureName)\"\n"
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

    private func pinCount() throws -> Int {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("gherkin/removal-pins.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let pins = root["pins"] as? [Any] else {
            throw RunnerError("removal-pins.json is not a pin list")
        }
        return pins.count
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
        if cleanMethod == "automatic:true" {
            let pinned = try pinCount()
            let checked = (summary?["pinsChecked"] as? Int) ?? -1
            guard checked == pinned else { throw RunnerError("the verifier checked \(checked) pinned objects, removal-pins.json has \(pinned): refusing to pass") }
        }
        let measured = (summary?["passed"] as? Int ?? 0) + (summary?["failed"] as? Int ?? 0)
        guard measured > 0 else { throw RunnerError("no \(trailClass) object was measurable: refusing to pass") }
    }

    private func starsPreserved() throws {
        guard let out = outputDir else { throw RunnerError("\"I process every frame\" has not run") }
        let report = try runVerifier(["--stars"], reportName: "stars")
        let frames = ((try? FileManager.default.contentsOfDirectory(atPath: try framesDirectory(out).path)) ?? []).filter { !$0.hasPrefix(".") }.count
        let stars = (report["stars"] as? [String: Any])?.count ?? 0
        guard stars == frames, frames > 0 else { throw RunnerError("the star check covered \(stars) frames, Star wrote \(frames): refusing to pass") }
    }

    // MARK: the binary

    /// `STAR_CLI_PATH`, else the `star` beside the test bundle (SwiftPM builds both into one products directory).
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
        let products = Bundle.main.bundleURL
        #endif
        let star = products.appendingPathComponent("star")
        guard FileManager.default.isExecutableFile(atPath: star.path) else {
            throw RunnerError("no star binary at \(star.path): run `swift build` first, or set STAR_CLI_PATH")
        }
        return star
    }
}
