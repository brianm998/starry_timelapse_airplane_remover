import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The "About the alignment charts" example charts: the generator gives the sample points of
/// `gherkin/ui/vectors/alignmentExamples.json`, which the desktop's `AlignmentExamplesTest` checks too.
final class AlignmentExamplesTests: XCTestCase {
    func testAlignmentExamplesMatchVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("gherkin/ui/vectors/alignmentExamples.json"))) as? [String: Any])
        XCTAssertEqual(doc["frameCount"] as? Int, AlignmentExamples.frameCount)
        XCTAssertEqual(doc["offsets"] as? [Int], AlignmentExamples.offsets)
        let cases: [(String, Bool, Bool)] = [
            ("fixedGood", false, true), ("fixedBad", false, false), ("movingGood", true, true), ("movingBad", true, false),
        ]
        for (name, moving, good) in cases {
            let points = AlignmentExamples.points(moving: moving, good: good)
            XCTAssertEqual(points.count, 48 * 8, name)
            XCTAssertTrue(points.allSatisfy { $0.alignmentState == .homographySuccess }, name)
            let samples = try XCTUnwrap(doc[name] as? [[String: Any]])
            XCTAssertGreaterThanOrEqual(samples.count, 12, "\(name) lost samples")
            for s in samples {
                let frame = try XCTUnwrap(s["frame"] as? Int)
                let offset = try XCTUnwrap(s["offset"] as? Int)
                let deviation = try XCTUnwrap(s["deviation"] as? Double)
                let isGood = try XCTUnwrap(s["good"] as? Bool)
                let p = try XCTUnwrap(points.first { $0.baseFrame == frame && $0.offset == offset })
                XCTAssertEqual(p.signedDeviation, deviation, accuracy: 0.0006, "\(name) \(frame) \(offset)")
                XCTAssertEqual(p.isGood, isGood, "\(name) \(frame) \(offset)")
            }
        }
    }
}
