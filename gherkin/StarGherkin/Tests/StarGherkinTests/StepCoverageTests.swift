import Foundation
import StarGherkinKernel
import XCTest

/// A step a feature uses that its client's runner does not implement fails at run time, in the middle of a feature that can take minutes
/// (the runners say so only when they reach it). This reads the three runners' dispatch tables and holds each to the steps its client's
/// generated features use, so the failure is here instead.
final class StepCoverageTests: XCTestCase {
    /// The repository root, from this file: gherkin/StarGherkin/Tests/StarGherkinTests/StepCoverageTests.swift.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Runner {
        let tag: String
        let path: String
        /// How a dispatch-table entry for [action] starts in this runner's source: `.clickId:` (Swift), `StepAction.CLICK_ID to` (Kotlin).
        let entry: (StepAction) -> [String]
    }

    private static func snake(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase && i > 0 { out.append("_") }
            out.append(contentsOf: String(ch).uppercased())
        }
        return out
    }

    private static func caseName(_ action: StepAction) -> String {
        // `StepAction` is `case saveScreenshot = "..."`: the case name is what `String(describing:)` prints
        String(describing: action)
    }

    private static let runners: [Runner] = [
        Runner(tag: "@cli", path: "cli/Tests/GherkinTests/CliFeatureRunner.swift") { [".\(caseName($0)):"] },
        Runner(tag: "@mac-gui", path: "gui/starUITests/GuiFeatureRunner.swift") { [".\(caseName($0)):"] },
        Runner(tag: "@desktop", path: "star-desktop/src/gherkinTest/kotlin/com/star/desktop/gherkin/DesktopFeatureRunner.kt") {
            ["StepAction.\(snake(caseName($0))) to"]
        },
    ]

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    func testEveryRunnerImplementsTheStepsItsFeaturesUse() throws {
        for runner in Self.runners {
            let text = try source(runner.path)
            var missing = Set<String>()
            var used = 0
            for feature in Features.all where feature.tags.contains(runner.tag) {
                for step in feature.steps {
                    used += 1
                    if !runner.entry(step.action).contains(where: { text.contains($0) }) {
                        missing.insert("\(step.action.rawValue)  (\(feature.id))")
                    }
                }
            }
            XCTAssertGreaterThan(used, 0, "\(runner.tag) has no features: the check would pass vacuously")
            XCTAssertTrue(missing.isEmpty, "\(runner.path) does not implement:\n" + missing.sorted().joined(separator: "\n"))
        }
    }

    /// The gallery needs both clients to save screenshots, and a gallery feature on each: a runner that dropped the step would otherwise only
    /// be found when a gallery is next made.
    func testBothUIClientsSaveScreenshots() throws {
        for runner in Self.runners where runner.tag != "@cli" {
            let text = try source(runner.path)
            for action in [StepAction.saveScreenshot, .saveWindowScreenshot] {
                XCTAssertTrue(runner.entry(action).contains { text.contains($0) }, "\(runner.path) has no entry for \"\(action.rawValue)\"")
            }
            let galleries = Features.all.filter { $0.id.hasPrefix("uiGallery") && $0.tags.contains(runner.tag) }
            XCTAssertFalse(galleries.isEmpty, "no uiGallery* feature runs on \(runner.tag)")
            XCTAssertTrue(galleries.contains { $0.steps.contains { $0.action == .saveScreenshot } }, "no uiGallery* feature of \(runner.tag) saves a screenshot")
        }
    }
}
