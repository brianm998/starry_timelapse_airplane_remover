import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// M2 of `plans/GUI_CLIENT_PARITY_PLAN.md`: `~/.star.userprefs.json` is written by both clients, so a save has to
/// change what *this* process changed and nothing else.  Encoding the whole struct dropped every key only the Kotlin
/// client knows (`outlierTableColumns`) and wrote this process's stale copy of any key the other one changed
/// meanwhile.
final class UserPreferencesMergeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("star-prefs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var path: String { dir.appendingPathComponent(".star.userprefs.json").path }

    private func obj(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func written() throws -> [String: Any] {
        try obj(String(contentsOfFile: path, encoding: .utf8))
    }

    func testThePathFollowsTheHomeEnvironmentWhenNotSandboxed() {
        XCTAssertEqual(
            UserPreferences.path(environment: ["HOME": "/scratch/home"], sandboxed: false, nsHomeDirectory: "/Users/real"),
            "/scratch/home/.star.userprefs.json")
        XCTAssertEqual(
            UserPreferences.path(environment: ["HOME": "/scratch/home"], sandboxed: true, nsHomeDirectory: "/container"),
            "/container/.star.userprefs.json")
        XCTAssertEqual(
            UserPreferences.path(environment: [:], sandboxed: false, nsHomeDirectory: "/Users/real"),
            "/Users/real/.star.userprefs.json")
        XCTAssertEqual(
            UserPreferences.path(environment: ["HOME": ""], sandboxed: false, nsHomeDirectory: "/Users/real"),
            "/Users/real/.star.userprefs.json")
    }

    func testAKeyOnlyTheOtherClientKnowsSurvivesASave() throws {
        try #"{"recentlyOpenedSequencelist":{},"outlierTableColumns":["rank","area"]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let before = try obj(#"{"recentlyOpenedSequencelist":{}}"#)
        let after = try obj(#"{"recentlyOpenedSequencelist":{},"showHorizonOnMainView":true}"#)

        XCTAssertEqual(try UserPreferences.writeMerged(current: after, previous: before, to: path), .written)

        let file = try written()
        XCTAssertEqual(file["outlierTableColumns"] as? [String], ["rank", "area"])
        XCTAssertEqual(file["showHorizonOnMainView"] as? Bool, true)
    }

    /// The other client changed a key after this process read the file; this process changed a different one.
    func testAKeyTheOtherClientChangedMeanwhileIsNotUndone() throws {
        try #"{"recentlyOpenedSequencelist":{},"language":"fr","showProcessingWindow":false}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        // what this process loaded: German, processing window on (nil is a missing key)
        let before = try obj(#"{"recentlyOpenedSequencelist":{},"language":"de"}"#)
        let after = try obj(#"{"recentlyOpenedSequencelist":{},"language":"de","showHorizonOnMainView":true}"#)

        _ = try UserPreferences.writeMerged(current: after, previous: before, to: path)

        let file = try written()
        XCTAssertEqual(file["language"] as? String, "fr", "the other client's language was put back")
        XCTAssertEqual(file["showProcessingWindow"] as? Bool, false)
        XCTAssertEqual(file["showHorizonOnMainView"] as? Bool, true)
    }

    func testAKeyThisProcessClearedIsRemoved() throws {
        try #"{"recentlyOpenedSequencelist":{},"language":"de","outlierTableColumns":["rank"]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let before = try obj(#"{"recentlyOpenedSequencelist":{},"language":"de"}"#)
        let after = try obj(#"{"recentlyOpenedSequencelist":{}}"#)

        _ = try UserPreferences.writeMerged(current: after, previous: before, to: path)

        let file = try written()
        XCTAssertNil(file["language"])
        XCTAssertNotNil(file["outlierTableColumns"])
    }

    /// D12: a recent the user took off the list is gone from the file, the others stay, and one the other client added meanwhile stays too.
    func testARecentTheUserRemovedIsRemovedAndTheOthersStay() throws {
        // another client opens /d after this process read the file
        try #"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/b/config.json":20,"/c/config.json":30,"/d/config.json":40}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let before = try obj(#"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/b/config.json":20,"/c/config.json":30}}"#)
        var prefs = UserPreferences()
        prefs.recentlyOpenedSequencelist = ["/a/config.json": 10, "/b/config.json": 20, "/c/config.json": 30]
        prefs.removeFromRecent(filename: "/b/config.json")
        XCTAssertEqual(prefs.sortedSequenceList, ["/c/config.json", "/a/config.json"])
        let after = try obj(#"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/c/config.json":30}}"#)

        _ = try UserPreferences.writeMerged(current: after, previous: before, to: path)

        let recent = try XCTUnwrap(try written()["recentlyOpenedSequencelist"] as? [String: Any])
        XCTAssertEqual(Set(recent.keys), ["/a/config.json", "/c/config.json", "/d/config.json"])
    }

    /// Recent files are one object: two clients opening different sequences both keep theirs.
    func testRecentFilesAddedByTheOtherClientAreKept() throws {
        try #"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/b/config.json":20}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        // this process loaded only /a, and has since opened /c
        let before = try obj(#"{"recentlyOpenedSequencelist":{"/a/config.json":10}}"#)
        let after = try obj(#"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/c/config.json":30}}"#)

        _ = try UserPreferences.writeMerged(current: after, previous: before, to: path)

        let recent = try XCTUnwrap(written()["recentlyOpenedSequencelist"] as? [String: Double])
        XCTAssertEqual(recent, ["/a/config.json": 10, "/b/config.json": 20, "/c/config.json": 30])
    }

    func testARecentFileThisProcessPrunedIsRemovedAndOthersKept() throws {
        try #"{"recentlyOpenedSequencelist":{"/a/config.json":10,"/b/config.json":20}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let before = try obj(#"{"recentlyOpenedSequencelist":{"/a/config.json":10}}"#)
        let after = try obj(#"{"recentlyOpenedSequencelist":{}}"#)

        _ = try UserPreferences.writeMerged(current: after, previous: before, to: path)

        let recent = try XCTUnwrap(written()["recentlyOpenedSequencelist"] as? [String: Double])
        XCTAssertEqual(recent, ["/b/config.json": 20])
    }

    func testNothingChangedWritesTheFileAsItWas() throws {
        try #"{"recentlyOpenedSequencelist":{},"language":"fr","outlierTableColumns":["rank"]}"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let same = try obj(#"{"recentlyOpenedSequencelist":{},"language":"de"}"#)

        _ = try UserPreferences.writeMerged(current: same, previous: same, to: path)

        let file = try written()
        XCTAssertEqual(file["language"] as? String, "fr")
        XCTAssertNotNil(file["outlierTableColumns"])
    }

    func testAFileThatIsNotAnObjectIsLeftAlone() throws {
        try "[1, 2".write(toFile: path, atomically: true, encoding: .utf8)
        let outcome = try UserPreferences.writeMerged(
            current: try obj(#"{"language":"de"}"#), previous: [:], to: path)
        XCTAssertEqual(outcome, .unreadable)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "[1, 2")
    }

    func testNoFileIsCreatedWithJustTheChange() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        _ = try UserPreferences.writeMerged(
            current: try obj(#"{"recentlyOpenedSequencelist":{},"language":"de"}"#),
            previous: try obj(#"{"recentlyOpenedSequencelist":{}}"#), to: path)
        XCTAssertEqual(try written()["language"] as? String, "de")
    }

    /// Slashes stay readable in the paths the file lists.
    func testPathsAreNotSlashEscaped() throws {
        _ = try UserPreferences.writeMerged(
            current: try obj(#"{"recentlyOpenedSequencelist":{"/a/b/config.json":1}}"#),
            previous: try obj(#"{"recentlyOpenedSequencelist":{}}"#), to: path)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("\"/a/b/config.json\""), text)
    }

    /// `save()` starts from `defaultObject` when no file was read; it has to be what an empty `UserPreferences` encodes to.
    func testTheDefaultObjectIsWhatAnEmptyPreferencesEncodesTo() throws {
        let empty = try JSONDecoder().decode(UserPreferences.self, from: Data(#"{"recentlyOpenedSequencelist":{}}"#.utf8))
        let encoded = try XCTUnwrap(UserPreferences.jsonObject(of: empty))
        XCTAssertEqual(NSDictionary(dictionary: encoded), NSDictionary(dictionary: UserPreferences.defaultObject))
    }

    /// The real struct round-trips through `jsonObject(of:)`, which is what `save()` compares.
    func testTheStructEncodesToAnObjectWithoutNilKeys() throws {
        var prefs = UserPreferences()
        let bare = try XCTUnwrap(UserPreferences.jsonObject(of: prefs))
        XCTAssertEqual(Set(bare.keys), ["recentlyOpenedSequencelist"])
        // (a copy that is never saved: `didSet` would write the real file otherwise, so set a field without observers)
        prefs = (try? JSONDecoder().decode(UserPreferences.self, from: Data(#"{"recentlyOpenedSequencelist":{},"language":"de"}"#.utf8))) ?? prefs
        let with = try XCTUnwrap(UserPreferences.jsonObject(of: prefs))
        XCTAssertEqual(with["language"] as? String, "de")
    }
}
