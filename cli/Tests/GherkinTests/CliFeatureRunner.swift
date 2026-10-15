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
        ]
    }

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        defer { try? FileManager.default.removeItem(at: scratch) }
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
    }

    private func processEveryFrame() throws {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let out = scratch.appendingPathComponent("output")
        let log = scratch.appendingPathComponent("star.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        let p = Process()
        p.executableURL = try starBinary()
        p.arguments = ["-l", "info", input.path, out.path]
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
