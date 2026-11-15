import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


@MainActor
final class RememberedHorizonCountTests: XCTestCase {

    private func preferred(_ total: Int, _ multiplier: Double?) -> Int {
        ImageSequenceViewModel.preferredMovingHorizonCount(total: total, multiplier: multiplier)
    }

    private func multiplier(chosen: Int, total: Int) -> Double {
        ImageSequenceViewModel.movingHorizonCountMultiplier(chosen: chosen, total: total)
    }

    // MARK: - with nothing remembered

    func testNoRecordedPreferenceLeavesTheSuggestionAlone() {
        XCTAssertEqual(preferred(1450, nil), 12)
        XCTAssertEqual(preferred(50, nil), 3)
    }

    // MARK: - what gets recorded

    func testAChoiceIsRecordedRelativeToWhatWasSuggested() {
        XCTAssertEqual(multiplier(chosen: 24, total: 1450), 2.0)   // star suggested 12
        XCTAssertEqual(multiplier(chosen: 6, total: 1450), 0.5)
        XCTAssertEqual(multiplier(chosen: 12, total: 1450), 1.0)
    }

    // MARK: - what it does next time

    /// The whole point: a choice made on one sequence carries proportionally to another length.
    func testTheMultiplierCarriesToADifferentSequenceLength() {
        let m = multiplier(chosen: 24, total: 1450) // "twice what star suggests"
        XCTAssertEqual(preferred(1450, m), 24)
        XCTAssertEqual(preferred(1000, m), 20)      // 10 suggested → 20
        XCTAssertEqual(preferred(5000, m), 44)      // 22 suggested → 44
    }

    /// Re-opening a sequence of the same length must offer exactly what was picked there, or
    /// the number would drift every time the user looked at it.
    func testRecordingThenApplyingRoundTripsForEveryCount() {
        for total in [1, 2, 10, 123, 1450, 6000] {
            for chosen in Set([1, 2, 3, total / 2, total]).filter({ (1...total).contains($0) }) {
                XCTAssertEqual(preferred(total, multiplier(chosen: chosen, total: total)), chosen,
                               "round trip \(chosen) of \(total)")
            }
        }
    }

    /// Asking for fewer has to be able to go below the suggestion curve's floor of 3 — the
    /// floor describes star's default taste, not a limit on the user's.
    func testAPreferenceForFewerGoesBelowTheFloorOfThree() {
        let m = multiplier(chosen: 1, total: 1000)  // 1 of the 10 suggested
        XCTAssertEqual(preferred(200, m), 1)        // 4 suggested × 0.1 → 1, not 3
        XCTAssertEqual(preferred(5000, m), 2)       // 22 suggested × 0.1 → 2
    }

    func testThePreferredCountIsAlwaysAValidStepperValue() {
        for m in [0.05, 0.5, 1.0, 2.5, 40.0] {
            for total in [1, 2, 3, 50, 1450, 6000] {
                let n = preferred(total, m)
                XCTAssertGreaterThanOrEqual(n, 1, "preferred \(n) below 1 at ×\(m)")
                XCTAssertLessThanOrEqual(n, total, "preferred \(n) above \(total) at ×\(m)")
            }
        }
    }

    /// A file written by hand, or by a future version, must not be able to produce a count the
    /// stepper cannot show.
    func testANonsenseMultiplierFallsBackToTheSuggestion() {
        XCTAssertEqual(preferred(1450, 0), 12)
        XCTAssertEqual(preferred(1450, -2), 12)
        XCTAssertEqual(preferred(1450, .nan), 12)
        XCTAssertEqual(preferred(1450, .infinity), 12)
    }

    /// A finite but preposterous multiplier scales past what an `Int` can hold, and converting
    /// that traps — so it has to be capped while it is still a `Double`.  This test crashes
    /// rather than fails if that ever regresses.
    func testAPreposterousMultiplierCapsAtTheSequenceInsteadOfTrapping() {
        XCTAssertEqual(preferred(1450, 1e6), 1450)
        XCTAssertEqual(preferred(1450, .greatestFiniteMagnitude), 1450)
        XCTAssertEqual(preferred(1, .greatestFiniteMagnitude), 1)
    }

    // MARK: - the shared preferences file

    /// The Kotlin client reads and writes this key by hand in the same `~/.star.userprefs.json`,
    /// while this side gets it from Codable synthesis — so the property name *is* the wire
    /// format, and renaming it would silently split the two clients' preferences.
    ///
    /// Decoded rather than assigned: assigning would fire the `didSet` that saves, and the test
    /// would overwrite the real preferences file of whoever ran it.
    func testTheMultiplierUsesTheSameKeyTheKotlinClientWrites() throws {
        // exactly what the Kotlin client's Gson wrote for a 1.5 multiplier, captured from it
        let json = #"{"recentlyOpenedSequencelist":{},"skipRenderPromptAfterProcessing":false,"movingHorizonCountMultiplier":1.5}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.movingHorizonCountMultiplier, 1.5)

        let round = try JSONEncoder().encode(prefs)
        let text = String(decoding: round, as: UTF8.self)
        XCTAssertTrue(text.contains("movingHorizonCountMultiplier"), "encoded as: \(text)")

        let back = try JSONDecoder().decode(UserPreferences.self, from: round)
        XCTAssertEqual(back.movingHorizonCountMultiplier, 1.5)
    }

    /// An older preferences file has no such key at all, which has to read as "no preference"
    /// rather than failing the whole file to decode.
    func testPreferencesWrittenBeforeThisFeatureStillDecode() throws {
        let json = #"{"recentlyOpenedSequencelist":{}}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.movingHorizonCountMultiplier)
        XCTAssertEqual(preferred(1450, prefs.movingHorizonCountMultiplier), 12)
    }

    /// The three GPU toggles are the same hand-written keys on the Kotlin side, so the property
    /// names are the wire format here too.  A file with none of them is the common case and has
    /// to read as "never chosen" — that is what leaves the sequence's own config in charge —
    /// and an explicit false has to survive as false, not collapse into that.
    func testTheGPUTogglesUseTheKeysTheKotlinClientWrites() throws {
        // exactly what the Kotlin client's Gson writes for a user who turned two of them off
        let json = #"{"recentlyOpenedSequencelist":{},"useGPUForMerge":false,"useGPUForAKAZE":false,"useGPUForSIFT":true}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.useGPUForMerge, false)
        XCTAssertEqual(prefs.useGPUForSIFT, true)
        XCTAssertEqual(prefs.useGPUForAKAZE, false)

        let round = try JSONEncoder().encode(prefs)
        let text = String(decoding: round, as: UTF8.self)
        for key in ["useGPUForMerge", "useGPUForSIFT", "useGPUForAKAZE"] {
            XCTAssertTrue(text.contains("\"\(key)\""), "\(key) not encoded as \(key): \(text)")
        }
        let back = try JSONDecoder().decode(UserPreferences.self, from: round)
        XCTAssertEqual(back.useGPUForMerge, false)
        XCTAssertEqual(back.useGPUForSIFT, true)
        XCTAssertEqual(back.useGPUForAKAZE, false)
    }

    func testPreferencesWithNoGPUChoiceLeaveItToTheSequence() throws {
        let json = #"{"recentlyOpenedSequencelist":{}}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.useGPUForMerge)
        XCTAssertNil(prefs.useGPUForSIFT)
        XCTAssertNil(prefs.useGPUForAKAZE)

        // and unset stays out of the file, so the Kotlin client sees no key rather than a null
        let text = String(decoding: try JSONEncoder().encode(prefs), as: UTF8.self)
        XCTAssertFalse(text.contains("useGPU"), "an unchosen toggle was written: \(text)")
    }
}
