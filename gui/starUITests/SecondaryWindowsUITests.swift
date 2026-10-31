import XCTest

/// M11 (D11) of the parity plan, in the real app (this file also holds the real-app checks of D12 below): each of the Window menu's items (and its ⌥ shortcut) toggles one window, instead of opening
/// a copy every time; the windows that are about a sequence are off on the start screen.
@MainActor
final class SecondaryWindowsUITests: XCTestCase {
    private let app = XCUIApplication()
    private var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-windows-\(UUID().uuidString)")
        let markers = scratch.appendingPathComponent("run-markers")
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        app.launchEnvironment["HOME"] = home.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func windows(titled title: String) -> Int {
        app.windows.matching(NSPredicate(format: "title == %@", title)).count
    }

    private func waitForCount(_ expected: Int, title: String) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if windows(titled: title) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return windows(titled: title) == expected
    }

    private func choose(_ item: String) {
        app.menuBars.menuBarItems["Window"].click()
        app.menuBars.menuItems[item].click()
    }

    func testTheMenuItemOpensOneWindowAndTheNextPressClosesIt() {
        XCTAssertEqual(windows(titled: "Star Debug"), 0)
        choose("Debug Window")
        XCTAssertTrue(waitForCount(1, title: "Star Debug"), "the Debug Window did not open")
        choose("Debug Window")
        XCTAssertTrue(waitForCount(0, title: "Star Debug"), "the second press did not close it (it opened another copy, or nothing)")
    }

    func testTheShortcutToggles() {
        app.typeKey("d", modifierFlags: .option)
        XCTAssertTrue(waitForCount(1, title: "Star Debug"), "⌥D did not open the Debug Window")
        app.typeKey("d", modifierFlags: .option)
        XCTAssertTrue(waitForCount(0, title: "Star Debug"), "a second ⌥D did not close it")
    }

    func testTheWindowsAboutASequenceAreOffOnTheStartScreen() {
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertFalse(app.menuBars.menuItems["Outlier Information Window"].isEnabled)
        XCTAssertFalse(app.menuBars.menuItems["Alignment Information Window"].isEnabled)
        XCTAssertTrue(app.menuBars.menuItems["Blob Processing Window"].isEnabled)
        XCTAssertTrue(app.menuBars.menuItems["Debug Window"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}

/// What a window of the real app does with a sequence open (D11): the windows about the sequence are on and go when the sequence does, the others stay.
@MainActor
final class SequenceWindowsUITests: XCTestCase {
    private let app = XCUIApplication()
    private var scratch: URL!

    /// What the outlier window calls itself (its own view sets it; the scene's title is not what shows).
    private static let outlierTitle = "Outliers Group Information"

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-seq-windows-\(UUID().uuidString)")
        let markers = scratch.appendingPathComponent("run-markers")
        let home = scratch.appendingPathComponent("home")
        let sequence = scratch.appendingPathComponent("seq")
        for dir in [markers, home, sequence] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        // a few frames of the repository's own sequence: enough to open, and quick to
        let source = Self.repoRoot.appendingPathComponent("test_data/test_a7sii_10")
        let frames = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".jpg") }.sorted().prefix(3)
        for name in frames { try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: sequence.appendingPathComponent(name)) }
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        app.launchEnvironment["HOME"] = home.path
        app.launchArguments += ["-StarUITestOpenSequence", sequence.path]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func windows(titled title: String) -> Int {
        app.windows.matching(NSPredicate(format: "title == %@", title)).count
    }

    private func waitForCount(_ expected: Int, title: String) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if windows(titled: title) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return windows(titled: title) == expected
    }

    private func choose(_ menu: String, _ item: String) {
        app.menuBars.menuBarItems[menu].click()
        app.menuBars.menuItems[item].click()
    }

    /// Open as a user does: no horizon, a fixed camera, and the question about what to remove is up.
    private func answerStartupQuestions() {
        let no = element("startup.horizon.no")
        XCTAssertTrue(no.waitForExistence(timeout: 120), "the startup questions did not appear")
        no.click()
        let fixed = element("startup.moving.static")
        XCTAssertTrue(fixed.waitForExistence(timeout: 30))
        fixed.click()
        XCTAssertTrue(element("startup.removal.start").waitForExistence(timeout: 60), "the removal question did not appear")
    }

    func testTheWindowsAboutTheSequenceGoWithItAndTheOthersStay() {
        answerStartupQuestions()

        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(app.menuBars.menuItems["Outlier Information Window"].isEnabled, "off with a sequence open")
        XCTAssertTrue(app.menuBars.menuItems["Alignment Information Window"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        choose("Window", "Outlier Information Window")
        XCTAssertTrue(waitForCount(1, title: Self.outlierTitle),
                      "the outlier window did not open; the windows are \(app.windows.allElementsBoundByIndex.map { $0.title })")
        choose("Window", "Debug Window")
        XCTAssertTrue(waitForCount(1, title: "Star Debug"), "the debug window did not open")

        choose("File", "Close")
        XCTAssertTrue(waitForCount(0, title: Self.outlierTitle), "the outlier window outlived its sequence")
        XCTAssertEqual(windows(titled: "Star Debug"), 1, "the debug window is not about the sequence and stays")

        app.menuBars.menuBarItems["Window"].click()
        XCTAssertFalse(app.menuBars.menuItems["Outlier Information Window"].isEnabled, "on again with no sequence")
        app.typeKey(.escape, modifierFlags: [])
    }
}

/// D12 (gui): the Open Recent picker's remove button takes the shown entry off the list and out of the preferences file, and the other entries stay.
@MainActor
final class RecentsUITests: XCTestCase {
    private let app = XCUIApplication()
    private var scratch: URL!
    private var prefs: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-recents-\(UUID().uuidString)")
        let home = scratch.appendingPathComponent("home")
        let markers = scratch.appendingPathComponent("run-markers")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        // two recents that exist (a recent that does not is dropped at launch), the second the newer
        var entries: [String: Double] = [:]
        for (i, name) in ["first", "second"].enumerated() {
            let dir = scratch.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = dir.appendingPathComponent("config.json")
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            entries[config.path] = Double(10 * (i + 1))
        }
        prefs = home.appendingPathComponent(".star.userprefs.json")
        try JSONSerialization.data(withJSONObject: ["recentlyOpenedSequencelist": entries]).write(to: prefs)
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        app.launchEnvironment["HOME"] = home.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func recents() throws -> [String] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: prefs)) as? [String: Any])
        return ((object["recentlyOpenedSequencelist"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    private func waitForRecents(_ count: Int) throws -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try recents().count == count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return try recents().count == count
    }

    func testTheRemoveButtonTakesTheShownRecentOffTheList() throws {
        let remove = app.descendants(matching: .any).matching(identifier: "startup.recent.remove").firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 60), "no remove button beside the Open Recent picker")
        XCTAssertEqual(try recents().count, 2)

        remove.click()
        XCTAssertTrue(try waitForRecents(1), "the entry was not taken out of the preferences file")
        let left = try recents()
        XCTAssertTrue(left[0].contains("/first/"), "the newer entry, the one shown, was the one removed: \(left)")

        remove.click()
        XCTAssertTrue(try waitForRecents(0), "the last entry was not removed")
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: remove)
        waitForExpectations(timeout: 8)
    }
}
