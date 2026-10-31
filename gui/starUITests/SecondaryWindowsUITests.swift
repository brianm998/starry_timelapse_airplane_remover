import XCTest

/// M11 (D11) of the parity plan, in the real app: each of the Window menu's items (and its ⌥ shortcut) toggles one window, instead of opening
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
