import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// Layer 0 of the parity plan (§6.2.4): the numbers `gherkin/ui/vectors/constants.json` holds are StarCore's, and the desktop copies them
/// by hand. This is the half that reads StarCore (and the startup prompt the gui offers them from); the desktop's test reads its copies.
final class SharedConstantsTests: XCTestCase {
    private static var path: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("gherkin/ui/vectors/constants.json")
    }

    private func doc() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.path)) as? [String: Any])
    }

    func testTheDiskSpaceRatioIsStarCores() throws {
        let disk = try XCTUnwrap(try doc()["diskSpace"] as? [String: Any])
        XCTAssertEqual(disk["peakToInputRatio"] as? Double, DiskSpaceCheck.peakToInputRatio)
        for c in try XCTUnwrap(disk["runBytes"] as? [[String: Any]]) {
            let input = (c["inputBytes"] as! NSNumber).uint64Value
            XCTAssertEqual(UInt64(Double(input) * DiskSpaceCheck.peakToInputRatio), (c["expected"] as! NSNumber).uint64Value, "\(input) bytes in")
        }
    }

    /// P14: the custom frame rate field takes 0.01 to 1000, as the desktop's does.
    func testTheCustomFrameRateRuleIsTheDesktops() throws {
        let rule = try XCTUnwrap(try doc()["customFrameRate"] as? [String: Any])
        XCTAssertEqual(RenderVideoSheetView.customFrameRateRange, (rule["min"] as! Double)...(rule["max"] as! Double))
        for c in try XCTUnwrap(rule["cases"] as? [[String: Any]]) {
            XCTAssertEqual(RenderVideoSheetView.customFrameRate(c["text"] as! String), c["expected"] as? Double, "\"\(c["text"] as! String)\"")
        }
    }

    private func cleanMethodName(_ method: CleanMethod) -> String {
        switch method {
        case .automatic(false): "automatic"
        case .automatic(true): "autoSelective"
        case .selective: "selective"
        case .dirty: "dirty"
        }
    }

    private func highLevel(_ name: String?) throws -> HighLevelCleanMethod {
        switch name {
        case "automatic": .automatic
        case "selective": .selective
        case "dirty": .dirty
        default: throw XCTSkip("no clean method choice named \(name ?? "nil")")
        }
    }

    /// I1: the title, hover text and paragraph under each clean-method row are catalogue keys the desktop's sheet reads too (they were English
    /// paragraphs written in StarCore, so a German gui showed English under a German heading).
    func testTheCleanMethodTextsAreTheDesktopsAndTranslated() throws {
        defer { StarLocalization.shared.languageOverride = nil }
        let texts = try XCTUnwrap(try XCTUnwrap(try doc()["cleanMethod"] as? [String: Any])["texts"] as? [String: Any])
        let clean = try XCTUnwrap(texts["cleanMethod"] as? [String: [String: String]])
        let auto = try XCTUnwrap(texts["selectiveAutoClean"] as? [String: [String: String]])
        for language in ["en", "de"] {
            StarLocalization.shared.languageOverride = language
            for (name, option) in [("automatic", HighLevelCleanMethod.automatic), ("selective", .selective),
                                   ("dirty", .dirty)] {
                let keys = try XCTUnwrap(clean[name])
                XCTAssertEqual(option.titleText, localized(try XCTUnwrap(keys["title"])), "\(name) in \(language)")
                XCTAssertEqual(option.helpText, localized(try XCTUnwrap(keys["tip"])), "\(name) in \(language)")
                XCTAssertEqual(option.descriptionText, localized(try XCTUnwrap(keys["description"])), "\(name) in \(language)")
            }
            for (name, option) in [("yes", AutoPreservationMode.yes), ("no", .no)] {
                let keys = try XCTUnwrap(auto[name])
                XCTAssertEqual(option.titleText, localized(try XCTUnwrap(keys["title"])), "\(name) in \(language)")
                XCTAssertEqual(option.helpText, localized(try XCTUnwrap(keys["tip"])), "\(name) in \(language)")
                XCTAssertEqual(option.descriptionText, localized(try XCTUnwrap(keys["description"])), "\(name) in \(language)")
            }
        }
        // Every one of them is a real catalogue entry, and German is not English.
        for keys in Array(clean.values) + Array(auto.values) {
            for key in ["tip", "description"] {
                let name = try XCTUnwrap(keys[key])
                StarLocalization.shared.languageOverride = "en"
                let english = localized(name)
                StarLocalization.shared.languageOverride = "de"
                XCTAssertNotEqual(english, name, "\(name) is missing from the catalogue")
                XCTAssertNotEqual(localized(name), english, "\(name) is English in German")
            }
        }
    }

    /// P6: the two questions behind a clean method, as the desktop's `CleanMethodChoice` puts them together.
    func testTheCleanMethodChoiceIsTheDesktops() throws {
        let rule = try XCTUnwrap(try doc()["cleanMethod"] as? [String: Any])
        for c in try XCTUnwrap(rule["cases"] as? [[String: Any]]) {
            let high = try highLevel(c["highLevel"] as? String)
            let preservation: AutoPreservationMode = (c["autoPreservation"] as? Bool) == true ? .yes : .no
            XCTAssertEqual(cleanMethodName(CleanMethod(highLevelCleanMethod: high, autoPreservationMode: preservation)), c["expected"] as? String, "\(c)")
        }
        for c in try XCTUnwrap(rule["autoPreservationStart"] as? [[String: Any]]) {
            let method: CleanMethod = switch c["method"] as? String { case "automatic": .automatic(false); case "autoSelective": .automatic(true); case "dirty": .dirty; default: .selective }
            // ProcessingSettingsView.init: the sheet opens with Selective Auto Clean at Yes whenever the method reviews outliers.
            XCTAssertEqual(method.usesOutliers, c["expected"] as? Bool, "\(c)")
        }
    }

    /// A5: choosing Dirty builds `.dirty`, whatever Selective Auto Clean was left at, and a
    /// clean method reads back as the choice it was made from.
    func testTheDirtyChoicesBuildTheMatchingCleanMethod() {
        for preservation in AutoPreservationMode.allCases {
            XCTAssertEqual(CleanMethod(highLevelCleanMethod: .dirty, autoPreservationMode: preservation), .dirty)
        }
        XCTAssertEqual(HighLevelCleanMethod.allCases, [.automatic, .selective, .dirty])
        for method: CleanMethod in [.automatic(false), .automatic(true), .selective, .dirty] {
            XCTAssertEqual(CleanMethod(highLevelCleanMethod: HighLevelCleanMethod(method), autoPreservationMode: method.usesOutliers ? .yes : .no).isDirty,
                           method.isDirty, "\(method)")
        }
        XCTAssertEqual(HighLevelCleanMethod(.dirty), .dirty)
        XCTAssertEqual(HighLevelCleanMethod(.automatic(true)), .automatic)
    }

    /// A2: only Automatic has a Selective Auto Clean row to answer; the dirty methods never use outliers, so the row is off for them.
    func testTheDirtyChoicesHaveNoAutoPreservationRow() throws {
        let rows = try XCTUnwrap(try XCTUnwrap(try doc()["cleanMethod"] as? [String: Any])["usesAutoPreservation"] as? [[String: Any]])
        XCTAssertEqual(rows.count, HighLevelCleanMethod.allCases.count)
        for c in rows {
            XCTAssertEqual(try highLevel(c["highLevel"] as? String).usesAutoPreservation, c["expected"] as? Bool, "\(c)")
        }
        XCTAssertFalse(CleanMethod.dirty.usesOutliers)
    }

    /// A5: Dirty needs no horizon, so nothing in the clean-method row is ever switched off and a config with horizon detection off
    /// and Dirty chosen has nothing to refuse.
    func testDirtyIsAlwaysAvailable() throws {
        XCTAssertEqual(HighLevelCleanMethod.allCases, [.automatic, .selective, .dirty])
        var config = Config()
        config.horizonDetectionEnabled = false
        config.cleanMethod = .dirty
        XCTAssertEqual(config.cleanMethod, .dirty)
    }

    /// Q7: the playback speeds the Display picker offers are the same in both clients.
    func testThePlaybackRatesAreTheDesktops() throws {
        XCTAssertEqual(try doc()["playbackFrameRates"] as? [Int], LeftPanel.playbackFrameRates)
    }

    func testTheKeypointDivisorChoicesAreTheStartupPromptsAndStarCores() throws {
        let k = try XCTUnwrap(try doc()["keypointDivisor"] as? [String: Any])
        XCTAssertEqual(k["recommendedReduced"] as? Double, Config.recommendedReducedKeypointDivisor)
        XCTAssertEqual(k["presets"] as? [Double], KeypointDivisorStartupView.presets.map(\.divisor))
        XCTAssertEqual(k["tooHigh"] as? Double, KeypointDivisorStartupView.tooHighDivisor)
        XCTAssertEqual(k["max"] as? Double, KeypointDivisorStartupView.maxDivisor)
    }

    /// A2: the cleanup dialog's summary names only the presets; any other value is the bare number.
    func testKeypointDivisorSummaryLabel() {
        StarLocalization.shared.languageOverride = "en"
        defer { StarLocalization.shared.languageOverride = nil }
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(1.0), "1 \u{2014} Best quality")
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(1.5), "1.5 \u{2014} Best balance")
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(2.0), "2 \u{2014} Fastest")
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(1.5004), "1.5 \u{2014} Best balance",
                       "a value that round-tripped through the config still names its preset")
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(3.0), "3")
        XCTAssertEqual(KeypointDivisorStartupView.summaryLabel(1.25), "1.25")
    }

    /// A1: the row's button says Change; the sheet's own confirm button is the one that says Update.
    func testKeypointDivisorRowButtonSaysChange() {
        StarLocalization.shared.languageOverride = "en"
        defer { StarLocalization.shared.languageOverride = nil }
        XCTAssertEqual(KeypointDivisorSummaryRow.buttonTitle, "Change")
        XCTAssertEqual(localized("ui.update"), "Update", "ui.update keeps its value: the settings sheet uses it too")
    }

    /// Art: the Change Mode dialog's clean choices map to their tiles; both dirty modes share one.
    func testSettingsChoiceArt() {
        XCTAssertEqual(SceneType.skyHorizon.settingsArt, .skyAndGround)
        XCTAssertEqual(SceneType.skyOnly.settingsArt, .skyOnly)
        XCTAssertEqual(CameraMotion.fixed.settingsArt, .cameraStatic)
        XCTAssertEqual(CameraMotion.moving.settingsArt, .cameraMoving)
        XCTAssertEqual(AutoPreservationMode.yes.settingsArt, .modeAutoSelective)
        XCTAssertNil(AutoPreservationMode.no.settingsArt)
    }

    func testChangeModeTiles() {
        XCTAssertEqual(HighLevelCleanMethod.automatic.changeModeArt, .changeModeAutomatic)
        XCTAssertEqual(HighLevelCleanMethod.selective.changeModeArt, .changeModeSelective)
        XCTAssertEqual(HighLevelCleanMethod.dirty.changeModeArt, .changeModeDirty)
        XCTAssertEqual(ArtImage(HighLevelCleanMethod.dirty.changeModeArt).displaySize, CGSize(width: 40, height: 40))
    }

    /// Art: each Welcome button shows its 48 pt tile; the greeter steps aside in small windows; the banner keeps the robot and dog.
    func testWelcomeButtonTiles() {
        XCTAssertEqual(InitialView.OpenKind.video.tileArt, .tileLoadVideo)
        XCTAssertEqual(InitialView.OpenKind.sequence.tileArt, .tileLoadSequence)
        XCTAssertEqual(InitialView.OpenKind.config.tileArt, .tileLoadConfig)
        for art in [StarArt.tileLoadVideo, .tileLoadSequence, .tileLoadConfig, .tileLearn] {
            XCTAssertEqual(ArtImage(art).displaySize, CGSize(width: 48, height: 48))
        }
        XCTAssertFalse(WelcomeArt.greeterShown(window: CGSize(width: 700, height: 500)))
        XCTAssertFalse(WelcomeArt.greeterShown(window: CGSize(width: 1280, height: 500)))
        XCTAssertTrue(WelcomeArt.greeterShown(window: CGSize(width: 1280, height: 800)))
        XCTAssertTrue(WelcomeArt.bannerTop <= 0.35 && WelcomeArt.bannerBottom >= 0.92)
        XCTAssertEqual(WelcomeArt.bannerHeight, 294)
    }

    private func assertPictures(_ rows: [StartupPictureChoice], _ expected: [(String, String, String, String)],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        StarLocalization.shared.languageOverride = "en"
        defer { StarLocalization.shared.languageOverride = nil }
        XCTAssertEqual(rows.count, expected.count, file: file, line: line)
        for (row, want) in zip(rows, expected) {
            XCTAssertEqual(row.id, want.0, file: file, line: line)
            XCTAssertEqual(row.art.rawValue, want.1, file: file, line: line)
            let word = localized(row.labelKey)
            XCTAssertEqual(word, want.2, file: file, line: line)
            XCTAssertNotNil(NSImage(named: row.art.rawValue), "\(want.1) is not in the asset catalog", file: file, line: line)
        }
    }

    /// A1
    func testHorizonQuestionPictures() throws {
        try assertPictures(StartupPictureChoice.horizon, [
            ("startup.horizon.no", "art_sky_only", "No", ""), ("startup.horizon.yes", "art_sky_and_ground", "Yes", "")])
    }

    /// A2
    func testCameraQuestionPictures() throws {
        try assertPictures(StartupPictureChoice.camera, [
            ("startup.moving.static", "art_camera_static", "Static", ""), ("startup.moving.moving", "art_camera_moving", "Moving", "")])
    }

    /// A3
    func testHorizonSelectionPictures() throws {
        try assertPictures(StartupPictureChoice.selectHorizon, [
            ("startup.selecthorizon.no", "art_horizon_auto", "No", ""), ("startup.selecthorizon.yes", "art_horizon_brush", "Yes", "")])
    }

    /// Cleanup sheet tiles: Automatic and Selective rows at 64 pt.
    func testCleanupModeRowTiles() throws {
        XCTAssertEqual(CleanupTiles.modeSize, 64)
        for (method, name) in [(CleanMethod.automatic(false), "art_mode_automatic"), (.selective, "art_mode_selective")] {
            let art = CleanupTiles.tile(for: method)
            XCTAssertEqual(art.rawValue, name)
            XCTAssertNotNil(NSImage(named: name), "\(name) is not in the asset catalog")
            let size = ArtImage(art, fitting: CleanupTiles.modeSize).displaySize
            XCTAssertEqual(max(size.width, size.height), 64)
        }
    }

    /// Cleanup sheet: the auto-selective switch at 40 pt, ground alignment at 48 pt.
    func testAutoSelectiveTile() throws {
        let art = CleanupTiles.tile(for: .automatic(true))
        XCTAssertEqual(art.rawValue, "art_mode_auto_selective")
        XCTAssertNotNil(NSImage(named: art.rawValue))
        let size = ArtImage(art, fitting: CleanupTiles.autoSelectiveSize).displaySize
        XCTAssertEqual(max(size.width, size.height), 40)
        XCTAssertEqual(CleanupTiles.groundAlignment.rawValue, "art_ground_alignment")
        let g = ArtImage(CleanupTiles.groundAlignment, fitting: CleanupTiles.groundAlignmentSize).displaySize
        XCTAssertEqual(max(g.width, g.height), 48)
    }

    /// Art A4: every StarArt slot is an imageset in the app's asset catalog and loads at its display size or larger.
    func testEveryStarArtSlotLoads() throws {
        XCTAssertEqual(StarArt.allCases.count, 84)
        for art in StarArt.allCases {
            let image = try XCTUnwrap(NSImage(named: art.rawValue), "\(art.rawValue) is not in the asset catalog")
            XCTAssertGreaterThan(image.size.width, 0, art.rawValue)
            XCTAssertGreaterThan(image.size.height, 0, art.rawValue)
            XCTAssertGreaterThan(art.size.width, 0, art.rawValue)
            XCTAssertGreaterThan(art.size.height, 0, art.rawValue)
        }
    }

    func testSpeedSharpnessPresetArt() {
        XCTAssertEqual(KeypointDivisorStartupView.presetArt(1.0), .presetBestQuality)
        XCTAssertEqual(KeypointDivisorStartupView.presetArt(1.5), .presetBestBalance)
        XCTAssertEqual(KeypointDivisorStartupView.presetArt(2.0), .presetFastest)
        XCTAssertNil(KeypointDivisorStartupView.presetArt(3.0))
        XCTAssertNil(KeypointDivisorStartupView.presetArt(1.25))
    }

    /// A3: the Speed vs. Sharpness sheet is all white text, so what it is drawn on must not be near-white.
    @MainActor
    func testSpeedSheetBackgroundIsNotWhite() throws {
        let view = KeypointDivisorStartupView(initial: 1.5, onCancel: {}, onUpdate: { _ in })
        // The field's `.cursor()` modifier reads the app's ViewModel from the environment.
        let renderer = ImageRenderer(content: view.environment(ViewModel()).frame(width: 700, height: 600, alignment: .topLeading))
        renderer.scale = 1
        let cg = try XCTUnwrap(renderer.cgImage, "the sheet did not render")
        let rep = NSBitmapImageRep(cgImage: cg)
        // The sheet sits at the top left; its first 24pt of padding hold no text or control.
        for (x, y) in [(4, 4), (4, 20), (20, 4)] {
            let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            XCTAssertGreaterThan(c.alphaComponent, 0.99, "nothing is drawn at (\(x), \(y)): the sheet would show the system's light background")
            XCTAssertLessThan(luminance, 0.75, "background at (\(x), \(y)) is near-white: \(c)")
        }
    }

    /// A2: an outlier group's mask image takes the decision colour where the group has pixels
    /// and leaves the background alone elsewhere.  The mask is the one `OutlierGroup.testImage()`
    /// builds, painted by the same helper `OutlierGroupView` uses.
    @MainActor
    func testOutlierGroupMaskPaintsEachDecisionColour() async throws {
        let set: Set<SortablePixel> = [SortablePixel(x: 0, y: 0, value: .sixteenBit(1000)),
                                       SortablePixel(x: 3, y: 1, value: .sixteenBit(1000))]
        let group = OutlierGroup(id: 1, size: 2, brightness: 1000,
                                 bounds: BoundingBox(min: Coord(x: 0, y: 0), max: Coord(x: 3, y: 1)),
                                 frameIndex: 0, imageWidth: 10, imageHeight: 10, pixels: [],
                                 pixelSet: set)
        let maybeMask = await group.testImage()
        let mask = try XCTUnwrap(maybeMask)
        let image = NSImage(cgImage: mask, size: CGSize(width: mask.width, height: mask.height))

        // (colour, index of the channel that must dominate) for remove, keep and undecided
        let decisions: [(String, Color, Int)] = [("remove", .red, 0), ("keep", .green, 1), ("undecided", .blue, 2)]
        for (name, color, channel) in decisions {
            let view = OutlierGroupView.maskView(image: image, color: color)
              .frame(width: 4, height: 2)
              .background(Color(white: 0.5))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let cg = try XCTUnwrap(renderer.cgImage, "\(name): the mask did not render")
            let rep = NSBitmapImageRep(cgImage: cg)

            func components(_ x: Int, _ y: Int) throws -> [CGFloat] {
                let c = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                return [c.redComponent, c.greenComponent, c.blueComponent]
            }
            for (x, y) in [(0, 0), (3, 1)] {
                let c = try components(x, y)
                let others = (0..<3).filter { $0 != channel }.map { c[$0] }
                // system colours are not pure primaries, so ask only that the channel clearly leads
                XCTAssertGreaterThan(c[channel], 0.8, "\(name): set pixel (\(x), \(y)) is \(c)")
                XCTAssertTrue(others.allSatisfy { $0 < c[channel] - 0.2 }, "\(name): set pixel (\(x), \(y)) is \(c)")
            }
            for (x, y) in [(1, 0), (2, 0), (1, 1), (0, 1)] {
                let c = try components(x, y)
                // the grey background, untinted (it reads back as ~0.57 after colour conversion)
                XCTAssertTrue(c.allSatisfy { abs($0 - c[0]) < 0.01 && abs($0 - 0.57) < 0.05 },
                              "\(name): unset pixel (\(x), \(y)) is \(c), not the background")
            }
        }
    }

    /// A4: the new key is translated in every language, not left as English.
    func testChangeKeyTranslatedEverywhere() throws {
        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(localized("ui.change"), "Change")
        let others = ["ar", "bn", "cs", "de", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl",
                      "pt-BR", "ru", "th", "tr", "uk", "ur", "vi", "zh-Hans"]
        for code in others {
            StarLocalization.shared.languageOverride = code
            let text = localized("ui.change")
            XCTAssertNotEqual(text, "ui.change", "\(code) is missing ui.change")
            XCTAssertNotEqual(text, "Change", "\(code) has English for ui.change")
        }
    }

    /// A5: Cancel keeps the value the sheet opened with; Update keeps the draft, a typed custom value included.
    func testKeypointDivisorDraftCancelAndUpdate() {
        var picked = KeypointDivisorDraft(original: 1.0)
        picked.choose(2.0)
        XCTAssertEqual(picked.committed, 2.0)
        XCTAssertEqual(picked.cancelled, 1.0)

        var typed = KeypointDivisorDraft(original: 1.5)
        typed.typed("3")
        typed.typed("3.")
        typed.typed("3.7")
        XCTAssertEqual(typed.committed, 3.7, "a typed custom value survives Update")
        XCTAssertEqual(typed.cancelled, 1.5)

        var junk = KeypointDivisorDraft(original: 2.0)
        junk.typed("")
        junk.typed("9")
        XCTAssertEqual(junk.committed, 2.0, "text that is not a value leaves the draft alone")
    }

    /// The settings sheet is tabs, and the desktop's are the same tabs in the same order, opening on the same one.
    func testTheSettingsTabsAreTheDesktops() throws {
        let rule = try XCTUnwrap(try doc()["settingsTabs"] as? [String: Any])
        XCTAssertEqual(SettingsTab.allCases.map(\.rawValue), rule["tabs"] as? [String])
        XCTAssertEqual(SettingsTab.first.rawValue, rule["default"] as? String, "the sheet opens on the first tab")
        // Every tab is named in the catalogue under its id, and the UI id a test finds it by ends in the same id.
        for tab in SettingsTab.allCases {
            XCTAssertEqual(tab.accessibilityId, "settings.tab.\(tab.rawValue)")
            StarLocalization.shared.languageOverride = "en"
            let english = tab.titleText
            XCTAssertNotEqual(english, "settings_tab.\(tab.rawValue)", "\(tab.rawValue) is missing from the catalogue")
            StarLocalization.shared.languageOverride = "de"
            XCTAssertNotEqual(tab.titleText, english, "\(tab.rawValue) is English in German")
        }
        StarLocalization.shared.languageOverride = nil
    }

    /// The sheet is tabs now: no button toggles a second, expert, half of it, and nothing in the view model remembers one.
    func testTheSettingsSheetHasNoExpertToggle() throws {
        let root = Self.path.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["gui/star/ProcessingSettingsView.swift", "gui/star/ImageSequenceViewModel.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(text.contains("showExpertSettings"), "\(name) still has the expert toggle")
            XCTAssertFalse(text.contains("ui.show_expert_settings"), name)
        }
        let sheet = try String(contentsOf: root.appendingPathComponent("gui/star/ProcessingSettingsView.swift"), encoding: .utf8)
        // Each tab is its own scroll view, so a tab taller than the window can still be reached.
        XCTAssertTrue(sheet.contains("ScrollView(.vertical)") && sheet.contains(".id(selectedTab)"), "each tab scrolls by itself")
    }
}
