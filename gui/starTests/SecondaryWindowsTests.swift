import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// M11 (D11) of the parity plan: the four secondary windows are single-instance scenes the Window menu toggles; the outlier and alignment
/// windows need a sequence and go when it does.  The desktop client's windows already behaved so.
final class SecondaryWindowsTests: XCTestCase {
    private static var guiDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("star")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: Self.guiDir.appendingPathComponent(name), encoding: .utf8)
    }

    func testTheMenuOpensAWindowAndClosesItWhenItIsOpen() {
        var state = SecondaryWindowState()
        XCTAssertEqual(state.menuAction(for: .outlier), .open)
        state.appeared(.outlier)
        XCTAssertEqual(state.menuAction(for: .outlier), .close, "the second press closes it; it used to open a second copy")
        XCTAssertEqual(state.menuAction(for: .blob), .open, "another window is not affected")
        state.disappeared(.outlier)
        XCTAssertEqual(state.menuAction(for: .outlier), .open, "closed by its own close button")
    }

    func testOnlyTheWindowsAboutASequenceNeedOne() {
        let state = SecondaryWindowState()
        for window in SecondaryWindow.allCases {
            XCTAssertTrue(state.isMenuItemEnabled(window, hasSequence: true))
        }
        XCTAssertFalse(state.isMenuItemEnabled(.outlier, hasSequence: false))
        XCTAssertFalse(state.isMenuItemEnabled(.alignment, hasSequence: false))
        XCTAssertTrue(state.isMenuItemEnabled(.blob, hasSequence: false), "a developer tool: any screen")
        XCTAssertTrue(state.isMenuItemEnabled(.debug, hasSequence: false), "the log is wanted most when nothing will open")
    }

    func testUnloadingTheSequenceClosesTheOutlierAndAlignmentWindowsOnly() {
        var state = SecondaryWindowState()
        for window in SecondaryWindow.allCases { state.appeared(window) }
        XCTAssertEqual(Set(state.closingWithTheSequence), [.outlier, .alignment])
        state.disappeared(.alignment)
        XCTAssertEqual(state.closingWithTheSequence, [.outlier], "one that is not open is not closed")
    }

    func testTheScenesAreSingleInstanceWindowsThatReportTheirState() throws {
        let app = try source("StarApp.swift")
        let names: [SecondaryWindow: String] = [
            .blob: "StarApp.blobProcessingStepsWindowName", .outlier: "StarApp.outlierGroupTableWindowName",
            .alignment: "StarApp.alignmentWindowName", .debug: "StarApp.debugWindowName",
        ]
        for window in SecondaryWindow.allCases {
            let name = try XCTUnwrap(names[window])
            XCTAssertTrue(app.contains("id: \(name)) {"), "\(window) is not a Window scene")
            XCTAssertFalse(app.contains("WindowGroup(id: \(name)"), "a window group opens a new copy every time")
            XCTAssertTrue(app.contains(".secondaryWindow(.\(window.rawValue), in: viewModel)"), "\(window) does not report when it is open")
        }
        XCTAssertTrue(app.contains("SecondaryWindowCommands(viewModel: viewModel)"))
        XCTAssertTrue(app.contains("closingWithTheSequence"), "nothing closes the windows when the sequence is unloaded")
    }
}
