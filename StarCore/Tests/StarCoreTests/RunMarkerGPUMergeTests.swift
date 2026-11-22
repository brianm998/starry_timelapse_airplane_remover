import XCTest
import StarCppBridge
@testable import StarCore

/// A run that dies inside a GPU merge is recognised from its marker, so the next session can start with
/// GPU merge off and say why.
final class RunMarkerGPUMergeTests: XCTestCase {

    private func marker() -> RunMarker {
        RunMarker(id: UUID().uuidString, client: "test", pid: 999_999)
    }

    func testAMergeInFlightIsDiedDuringGPUMerge() {
        var m = marker()
        m.gpuMergesInFlight = 2
        XCTAssertTrue(m.diedDuringGPUMerge)
        m.gpuMergeEnabled = false   // in flight is direct evidence, whatever the flag says
        XCTAssertTrue(m.diedDuringGPUMerge)
    }

    func testAMergePhaseWithGPUMergeEnabledIs() {
        for phase in ["mergingHorizon", "creatingEarthAlignedFrame", "creatingStarAlignedFrame"] {
            var m = marker()
            m.gpuMergesInFlight = 0
            m.gpuMergeEnabled = true
            m.currentPhase = phase
            XCTAssertTrue(m.diedDuringGPUMerge, phase)
        }
    }

    func testDyingElsewhereOrWithGPUMergeOffIsNot() {
        var m = marker()
        XCTAssertFalse(m.diedDuringGPUMerge, "nothing recorded")
        m.gpuMergeEnabled = true
        m.currentPhase = "findingKeypoints"
        m.gpuMergesInFlight = 0
        XCTAssertFalse(m.diedDuringGPUMerge, "died in another phase")
        m.currentPhase = "mergingHorizon"
        m.gpuMergeEnabled = false
        XCTAssertFalse(m.diedDuringGPUMerge, "GPU merge was off")
        m.gpuMergeEnabled = nil
        XCTAssertFalse(m.diedDuringGPUMerge, "old marker: no evidence")
    }

    func testOldMarkerDecodes() throws {
        let json = """
          {"formatVersion":1,"id":"a","client":"Star","starVersion":"1.0.0","pid":999999,
           "startedAt":"2026-10-13T10:00:00Z","heartbeatAt":"2026-10-13T10:05:00Z",
           "hostPhysicalMemoryBytes":17179869184,"framesCompleted":4,"peakFootprintBytes":0}
          """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let m = try decoder.decode(RunMarker.self, from: Data(json.utf8))
        XCTAssertNil(m.gpuMergesInFlight)
        XCTAssertNil(m.gpuMergeEnabled)
        XCTAssertFalse(m.diedDuringGPUMerge)
    }

    func testNewFieldsRoundTrip() throws {
        var m = marker()
        m.gpuMergesInFlight = 3
        m.gpuMergeEnabled = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(RunMarker.self, from: try encoder.encode(m))
        XCTAssertEqual(back.gpuMergesInFlight, 3)
        XCTAssertEqual(back.gpuMergeEnabled, true)
    }

    func testTheCounterIsZeroWhenNothingMerges() {
        XCTAssertEqual(GPUOps.mergesInFlight, 0)
    }

    func testTheWarningSaysWhatHappened() {
        let w = marker().asGPUMergeWarning
        XCTAssertEqual(w.kind, .gpuMergeTurnedOff)
        XCTAssertEqual(w.severity, .warning)
        XCTAssertFalse(w.message.isEmpty)
        XCTAssertFalse(w.message.hasPrefix("warning."), "the key resolved")
        XCTAssertNotNil(w.suggestion)
        XCTAssertFalse(w.title.hasPrefix("warning."))
    }
}
