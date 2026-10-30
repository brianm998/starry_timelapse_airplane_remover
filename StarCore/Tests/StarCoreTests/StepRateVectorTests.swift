import XCTest
@testable import StarCore

/// Layer 0 of the parity plan (§6.2.4): `StepRateTracker` (the gui's "about N left" per step) is held to
/// `gherkin/ui/vectors/stepRates.json`, and the desktop's copy of it to the same scenarios (`StepRateVectorTest`).
final class StepRateVectorTests: XCTestCase {

    private func doc() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gherkin/ui/vectors/stepRates.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The vector names a step by its case ("starKeypoints"), not by its raw value ("star kp").
    private func step(_ json: [String: Any]) throws -> ProcessingStepProgress {
        let name = try XCTUnwrap(json["type"] as? String)
        let type = try XCTUnwrap(OperationType.allCases.first { "\($0)" == name }, name)
        return ProcessingStepProgress(type: type,
                                      queued: try XCTUnwrap(json["queued"] as? Int),
                                      running: try XCTUnwrap(json["running"] as? Int),
                                      done: try XCTUnwrap(json["done"] as? Int),
                                      alreadyDone: try XCTUnwrap(json["alreadyDone"] as? Int))
    }

    func testTheConstantsAreTheVectors() throws {
        let doc = try doc()
        XCTAssertEqual(doc["minimumOperations"] as? Int, StepRateTracker.minimumOperations)
        XCTAssertEqual(doc["minimumSeconds"] as? Double, StepRateTracker.minimumSeconds)
    }

    func testEveryScenarioIsWhatTheTrackerSays() throws {
        let scenarios = try XCTUnwrap(try doc()["scenarios"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(scenarios.count, 10)
        for scenario in scenarios {
            let name = try XCTUnwrap(scenario["name"] as? String)
            let tracker = StepRateTracker()
            let start = Date(timeIntervalSinceReferenceDate: 0)
            for observation in try XCTUnwrap(scenario["observations"] as? [[String: Any]]) {
                let ms = try XCTUnwrap(observation["timeMs"] as? Int)
                let steps = try XCTUnwrap(observation["steps"] as? [[String: Any]]).map(step)
                tracker.observe(steps, at: start.addingTimeInterval(Double(ms) / 1000))
            }
            let got = tracker.secondsRemaining(for: try step(try XCTUnwrap(scenario["query"] as? [String: Any])))
            if let expected = scenario["expected"] as? Double {
                XCTAssertEqual(try XCTUnwrap(got, name), expected, accuracy: 1e-9, name)
            } else {
                XCTAssertNil(got, name)
            }
        }
    }
}
