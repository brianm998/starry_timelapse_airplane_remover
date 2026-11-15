import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The re-open panel's Settings button: what it does is in the view model, which cannot be
/// built in a test without a real sequence (it opens a `FrameSource` and writes run markers),
/// so the wiring is read from the sources, as `VideoRenderWiringTests` does.
final class ProcessingArtTests: XCTestCase {
    func testProcessingArtTurnsWhileOpen() throws {
        XCTAssertEqual(processingArt(reduceMotion: false), .animated)
        XCTAssertEqual(ProcessingRobot.secondsPerTurn, 4)
        XCTAssertEqual(ProcessingRobot.box, 56)
        // The gear sits on its PR-1 hub and is about half the box.
        XCTAssertEqual(ProcessingRobot.hubX, 0.698, accuracy: 0.001)
        XCTAssertEqual(ProcessingRobot.hubY, 0.677, accuracy: 0.001)
        XCTAssertEqual(ProcessingRobot.gearSize, 29)
        XCTAssertEqual(ArtImage(.processBody).displaySize.height, 56)
        XCTAssertEqual(ArtImage(.processGear, fitting: ProcessingRobot.gearSize).displaySize.width, 29)
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: dir.appendingPathComponent("star/ProcessingModalView.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("accessibilityIdentifier(\"processing.modal\")"))
        let header = src.components(separatedBy: "private var header: some View {")[1]
            .components(separatedBy: "ProcessingRobotView()")[0]
        XCTAssertFalse(header.contains("ProgressView()"), "the spinner is gone from the header")
        // Starts on appear, stops on disappear.
        XCTAssertTrue(src.contains(".linear(duration: ProcessingRobot.secondsPerTurn).repeatForever(autoreverses: false)"))
        XCTAssertTrue(src.contains(".onDisappear"))
    }

    func testProcessingArtStillUnderReduceMotion() {
        XCTAssertEqual(processingArt(reduceMotion: true), .still)
        XCTAssertEqual(StarArt.process.rawValue, "art_process")
    }
}
