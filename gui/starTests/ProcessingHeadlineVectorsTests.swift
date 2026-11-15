import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 of the parity plan (§6.2.4): the processing headline is StarCore's, and the Kotlin client keeps a copy of it
/// (`ProcessingHeadline.kt`), which had already drifted once.  `gherkin/ui/vectors/processingHeadline.json` holds inputs and the
/// output StarCore gives for them; this test checks StarCore still gives it, and the Kotlin client's test checks its copy against the
/// same file.  `TEST_RUNNER_STAR_VECTORS_RECORD=1` rewrites the file from what StarCore says now, to be reviewed in the diff.
final class ProcessingHeadlineVectorsTests: XCTestCase {
    private static var path: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gherkin/ui/vectors/processingHeadline.json")
    }

    private static let types: [String: OperationType] = [
        "horizon": .horizon, "mergedHorizon": .mergedHorizon, "starKeypoints": .starKeypoints, "earthKeypoints": .earthKeypoints,
        "starHomography": .starHomography, "earthHomography": .earthHomography, "horizonConsensus": .horizonConsensus,
        "outliers": .outliers, "merge": .merge,
    ]

    override func setUp() {
        StarLocalization.shared.languageOverride = "en"
    }

    override func tearDown() {
        StarLocalization.shared.languageOverride = nil
    }

    private func steps(_ list: [[String: Any]]) throws -> [ProcessingStepProgress] {
        try list.map { s in
            ProcessingStepProgress(
                type: try XCTUnwrap(Self.types[s["type"] as? String ?? ""], "unknown step type \(s["type"] ?? "nil")"),
                queued: s["queued"] as? Int ?? 0, running: s["running"] as? Int ?? 0, done: s["done"] as? Int ?? 0,
                alreadyDone: s["alreadyDone"] as? Int ?? 0)
        }
    }

    func testStarCoreGivesTheRecordedHeadlines() throws {
        var doc = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.path)) as? [String: Any])
        let recording = ProcessInfo.processInfo.environment["STAR_VECTORS_RECORD"] != nil
        var mismatches: [String] = []

        // What the file held, for checking against, while the copies below take the new values for recording.
        let originals = doc
        func expectedOf(_ section: String, _ i: Int) -> Any? {
            ((originals[section] as? [[String: Any]])?[i])?["expected"]
        }

        var headlines: [[String: Any]] = []
        for (i, c) in (doc["headline"] as! [[String: Any]]).enumerated() {
            var c = c
            var extraction: FrameExtractionProgress?
            if let e = c["extraction"] as? [String: Any] {
                let eta = e["etaSeconds"] as? Double ?? 0
                let known = e["etaKnown"] as? Bool ?? false
                let error = e["error"] as? String ?? ""
                extraction = FrameExtractionProgress(extracted: 0, total: Int(eta), framesPerSecond: known ? 1.0 : nil, isComplete: false,
                                                     error: error.isEmpty ? nil : error)
            }
            let got = ProcessingHeadline.text(
                steps: try steps(c["steps"] as! [[String: Any]]), extraction: extraction, hasPlan: c["hasPlan"] as! Bool,
                framesComplete: c["framesComplete"] as! Int, frameCount: c["frameCount"] as! Int)
            let want = expectedOf("headline", i)
            if !recording, got != (want as? String) {
                mismatches.append("headline \(c["name"] ?? i): StarCore says \(String(describing: got)), the file says \(String(describing: want))")
            }
            c["expected"] = got ?? NSNull()
            headlines.append(c)
        }
        var durations: [[String: Any]] = []
        for (i, c) in (doc["duration"] as! [[String: Any]]).enumerated() {
            var c = c
            let got = ProcessingHeadline.duration((c["seconds"] as! NSNumber).doubleValue)
            let want = expectedOf("duration", i)
            if !recording, got != (want as? String) { mismatches.append("duration \(c["seconds"] ?? i): StarCore says \(got), the file says \(String(describing: want))") }
            c["expected"] = got
            durations.append(c)
        }
        var overalls: [[String: Any]] = []
        for (i, c) in (doc["overall"] as! [[String: Any]]).enumerated() {
            var c = c
            let remaining = c["secondsRemaining"] as! [String: Double]
            let list = try steps(c["steps"] as! [[String: Any]])
            let byType = Dictionary(uniqueKeysWithValues: Self.types.compactMap { name, type in remaining[name].map { (type, $0) } })
            let got = ProcessingHeadline.overallText(steps: list, secondsRemaining: { byType[$0.type] })
            let want = expectedOf("overall", i)
            if !recording, got != (want as? String) {
                mismatches.append("overall \(c["name"] ?? i): StarCore says \(String(describing: got)), the file says \(String(describing: want))")
            }
            c["expected"] = got ?? NSNull()
            overalls.append(c)
        }

        if recording {
            doc["headline"] = headlines
            doc["duration"] = durations
            doc["overall"] = overalls
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: Self.path)
            return
        }
        XCTAssertEqual(mismatches, [], "StarCore's headline no longer matches gherkin/ui/vectors/processingHeadline.json")
    }
}
