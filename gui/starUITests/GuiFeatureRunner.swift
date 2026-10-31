import Foundation
import StarGherkinKernel
import XCTest

/// Runs a generated `Feature` against the real `Star.app` with XCUITest. The step vocabulary is
/// `StepAction`; every case has to appear in `methodMap` or the run fails naming what is implemented.
///
/// The app is opened on the sequence through its `-StarUITestOpenSequence <dir>` launch argument (the open
/// panel is the only other way in and cannot be driven), and every control a step touches carries an
/// accessibility identifier: `startup.*`, `prompt.pre.no` and `processing.progress`.
@MainActor
final class GuiFeatureRunner {
    struct RunnerError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let client = "mac-gui"

    let testCase: XCTestCase
    private let app = XCUIApplication()
    private let scratch: URL
    private var feature: Feature?
    private var sequenceCopy: URL?             // what the app was opened on: a sequence directory, or a video file
    private var sourceVideo: URL?
    private var inputFrames: URL?              // the frames Star processes (the decoded ones, for a video)
    private var completeFrames: Int?
    private var rendersVideo = false
    private var finishedReview = false
    /// What the step being run was given for its inline arguments (`I click "<id>"`).
    private var args: [String] = []
    private var settledOnce = false
    /// The video's frames are extracted while the run is going, not before it.
    private var backgroundImport = false

    // The setting steps, applied as the startup prompts when the sequence opens (the generator makes them precede the open step).
    private var horizon: Bool?
    private var moving: Bool?
    private var clean: String?                 // auto | selective | autoSelective, the validator's spelling

    init(testCase: XCTestCase) {
        self.testCase = testCase
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-\(UUID().uuidString)")
    }

    // MARK: dispatch table

    static let methodMap: [StepAction: (GuiFeatureRunner) throws -> Void] = [
        .horizonYes: { $0.horizon = true },
        .horizonNo: { $0.horizon = false },
        .cameraStatic: { $0.moving = false },
        .cameraMoving: { $0.moving = true },
        .cleanAuto: { $0.clean = "auto" },
        .cleanSelective: { $0.clean = "selective" },
        .cleanAutoSelective: { $0.clean = "autoSelective" },
        .openSequence: { try $0.openSequence() },
        .importVideo: { try $0.importVideo() },
        .importVideoBackground: { try $0.importVideo(inBackground: true) },
        .processEveryFrame: { try $0.processEveryFrame() },
        .renderOutputVideo: { try $0.renderOutputVideoStep() },
        .usedRequestedSettings: { try $0.usedRequestedSettings() },
        .everyFrameOutput: { try $0.everyFrameOutput() },
        .outputKeepsFormat: { try $0.outputKeepsFormat() },
        .processedAuto: { try $0.processedIn("auto") },
        .processedSelective: { try $0.processedIn("selective") },
        .processedAutoSelective: { try $0.processedIn("autoSelective") },
        .outputVideoMatches: { try $0.outputVideoMatches() },
        .noProblems: { try $0.noProblems() },
        .airplanesRemoved: { try $0.trailsRemoved(trailClass: "airplane") },
        .satellitesRemoved: { try $0.trailsRemoved(trailClass: "satellite") },
        .starsPreserved: { try $0.starsPreserved() },
        .nothingElseChanged: { try $0.nothingElseChanged() },
        // the @ui vocabulary
        .copySequence: { try $0.copySequenceStep() },
        .openCopied: { try $0.openCopiedSequence() },
        .openCopiedNoQuestions: { try $0.openCopiedSequence(askingTheStartupQuestions: false) },
        .clickId: { try $0.clickId($0.args[0]) },
        .pressKey: { try $0.press($0.args[0]) },
        .idShown: { try $0.expectShown($0.args[0], shown: true) },
        .idNotShown: { try $0.expectShown($0.args[0], shown: false) },
        .idSelected: { try $0.expectSelected($0.args[0], selected: true) },
        .idNotSelected: { try $0.expectSelected($0.args[0], selected: false) },
        .idOn: { try $0.expectOn($0.args[0], on: true) },
        .idOff: { try $0.expectOn($0.args[0], on: false) },
        .idReads: { try $0.expectReads($0.args[0], key: $0.args[1]) },
        .idSays: { try $0.expectSays($0.args[0], text: $0.args[1]) },
        .typeInto: { try $0.typeInto($0.args[0], into: $0.args[1]) },
        .idHolds: { try $0.expectHolds($0.args[0], number: Int($0.args[1]) ?? -1) },
        .idFocused: { try $0.expectFocus($0.args[0], focused: true) },
        .idNotFocused: { try $0.expectFocus($0.args[0], focused: false) },
        .languageIs: { _ in },   // read by `language` when the app is launched
        .appNoSequence: { try $0.launch(arguments: []) },
        .prefsRecents: { try $0.seedRecents(Int($0.args[0]) ?? 0) },
        .prefsListRecents: { try $0.expectRecents(Int($0.args[0]) ?? -1) },
        .prefsFixture: { try $0.seedPreferences(fixture: $0.args[0]) },
        .prefsUnchanged: { try $0.expectPreferencesUnchanged(fixture: $0.args[0]) },
        .prefsHasKey: { try $0.expectPreferencesKey($0.args[0]) },
        .prefsKeepsCopy: { try $0.expectUndecodableCopy(fixture: $0.args[0]) },
        .menuChoose: { try $0.chooseMenuCommand($0.args[0]) },
        .menuEnabled: { try $0.expectMenuCommand($0.args[0], enabled: true) },
        .menuDisabled: { try $0.expectMenuCommand($0.args[0], enabled: false) },
        .menuThere: { try $0.expectMenu($0.args[0], there: true) },
        .menuNotThere: { try $0.expectMenu($0.args[0], there: false) },
        .dragAround: { try $0.drag(around: $0.args[0]) },
        .processedCopy: { try $0.makeProcessedCopy() },
        .openProcessed: { try $0.openProcessedCopy() },
        .confirmCloseIfAsked: { try $0.confirmClosingIfAsked() },
        .windowOpen: { try $0.expectWindow($0.args[0], open: true) },
        .windowNotOpen: { try $0.expectWindow($0.args[0], open: false) },
    ]

    func run(_ feature: Feature) throws {
        guard !feature.steps.isEmpty else { throw RunnerError("feature \"\(feature.name)\" has no steps: refusing to pass vacuously") }
        testCase.continueAfterFailure = false
        self.feature = feature
        // The pre-processing prompt asks whether to render afterwards, which is where this client chooses it.
        rendersVideo = feature.steps.contains { $0.action == .renderOutputVideo }
        defer {
            saveArtifacts(of: feature)
            if app.state != .notRunning { app.terminate() }
            try? FileManager.default.removeItem(at: scratch)
        }
        // A @ui feature that fails where gherkin/ui/known-gaps.json says it does passes, and says so; one that passes there fails until the
        // entry is removed (the parity backlog is that file, and it only shrinks).
        let gap = feature.tags.contains("@ui") ? Self.knownGap(feature.id) : nil
        do {
            for step in feature.steps {
                guard let method = Self.methodMap[step.action] else {
                    throw RunnerError("no method for step \"\(step.description)\". Implemented steps:\n"
                                      + Self.methodMap.keys.map { "  \($0.rawValue)" }.sorted().joined(separator: "\n"))
                }
                args = step.args
                try XCTContext.runActivity(named: step.description) { _ in
                    do { try method(self) } catch {
                        // said here as well: the cleanup that follows can raise issues of its own and bury this one
                        print("STEP FAILED: \(step.description): \(error)")
                        throw error
                    }
                }
            }
        } catch {
            if let gap {
                print("KNOWN GAP \(feature.id) on \(Self.client): \(gap)\n  it failed with: \(error)")
                return
            }
            throw error
        }
        if let gap {
            throw RunnerError("\(feature.id) passes on \(Self.client), and gherkin/ui/known-gaps.json still lists it as a gap (\(gap)): remove the entry")
        }
    }

    /// Why `feature` is a known gap of this client, from gherkin/ui/known-gaps.json; nil when it is not one.
    static func knownGap(_ feature: String) -> String? {
        let url = repoRoot.appendingPathComponent("gherkin/ui/known-gaps.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gaps = object["gaps"] as? [String: Any],
              let entry = gaps[feature] as? [String: String] else { return nil }
        return entry[client]
    }

    // MARK: placeholders

    private func param(_ name: String) throws -> String {
        // xcodebuild forwards TEST_RUNNER_STAR_GHERKIN_<NAME> to the runner as STAR_GHERKIN_<NAME>.
        guard let v = Params.resolve(name, client: Self.client, feature: feature?.id, environment: ProcessInfo.processInfo.environment) else {
            throw RunnerError("no value for {\(name)}")
        }
        return v
    }

    /// The repository root, from this file's own path: gui/starUITests/GuiFeatureRunner.swift.
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: element lookup

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func tap(_ identifier: String, timeout: TimeInterval = 120) throws {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else {
            throw RunnerError("\(identifier) did not appear within \(Int(timeout))s\n\(app.debugDescription)")
        }
        e.click()
    }

    /// Drags a small box around the element: from a point up and to the left of its centre to one down and to the right, held a moment first so
    /// that it is a drag and not a click. What is under the pointer gets it: the frame's canvas, for a group's probe.
    private func drag(around identifier: String, timeout: TimeInterval = 120) throws {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else {
            throw RunnerError("\(identifier) did not appear within \(Int(timeout))s\n\(app.debugDescription)")
        }
        let centre = e.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        centre.withOffset(CGVector(dx: -12, dy: -12)).press(forDuration: 0.2, thenDragTo: centre.withOffset(CGVector(dx: 12, dy: 12)))
    }

    /// Clicks the element; if it exists but cannot be hit (on a small display the sheet's lower buttons can sit below the
    /// screen's edge, as on hosted runners), presses Return instead, which is that button's default action.
    private func activateDefault(_ identifier: String, timeout: TimeInterval = 120) throws {
        let e = element(identifier)
        guard e.waitForExistence(timeout: timeout) else {
            throw RunnerError("\(identifier) did not appear within \(Int(timeout))s\n\(app.debugDescription)")
        }
        if e.isHittable { e.click() } else { app.typeKey(.return, modifierFlags: []) }
    }

    /// Polls `condition` until it holds. Real-time waits only, never a fixed sleep.
    /// `interval`: a busy app (the horizon overlays, previews) can take longer than XCUITest's snapshot timeout to answer, which fails the
    /// test outright, so the long waits poll slowly.
    private func waitFor(_ what: String, timeout: TimeInterval, interval: TimeInterval = 1, detail: () -> String = { "" }, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw RunnerError("timed out after \(Int(timeout))s waiting for \(what) \(detail())") }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "poll")], timeout: interval)
        }
    }

    /// The test-data cache, by the fetch tool's rule. Under xcodebuild it arrives as `TEST_RUNNER_STAR_TEST_DATA` (prefix stripped);
    /// otherwise `<repoRoot>/.test-data`.
    private func dataCache() -> URL {
        if let c = ProcessInfo.processInfo.environment["STAR_TEST_DATA"], !c.isEmpty { return URL(fileURLWithPath: c) }
        return Self.repoRoot.appendingPathComponent(".test-data")
    }

    // MARK: steps

    private func requireSettings() throws -> (horizon: Bool, moving: Bool, clean: String) {
        guard let h = horizon, let m = moving, let c = clean else {
            throw RunnerError("horizon, camera and clean method steps must all come before the open or import step")
        }
        return (h, m, c)
    }

    /// Launches the app with a fresh run-marker directory: a marker left by an earlier launch would raise the
    /// "previous run crashed" critical alert over the window.
    private func launch(arguments: [String]) throws {
        let markers = scratch.appendingPathComponent("run-markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        app.launchEnvironment["STAR_RUN_MARKER_DIR"] = markers.path
        // a @ui feature may compare what the app says with the English catalogue
        if feature?.tags.contains("@ui") == true { app.launchEnvironment["STAR_LANG"] = language }
        if let floor = ProcessInfo.processInfo.environment["STAR_SYSTEM_FLOOR_MB"], !floor.isEmpty {
            app.launchEnvironment["STAR_SYSTEM_FLOOR_MB"] = floor
        }
        // The app keeps its preferences in $HOME/.star.userprefs.json. A test must neither read nor write the real one: a "don't ask me
        // again" answered on this machine once skipped the render prompt and with it the video the feature asked for.
        let home = scratch.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        app.launchEnvironment["HOME"] = home.path
        // Ignore the windows the last run of the app left open (macOS restores them): a feature starts from the app as it opens, not from where an earlier one quit.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launch()
    }

    // MARK: the @ui steps

    /// A fresh copy of the sequence, as `openSequence` makes one: star derives its temp and output paths from the input directory's name.
    private func copySequenceStep() throws {
        let given = try param("sequence")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError("sequence directory not found: \(source.path)")
        }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        sequenceCopy = copy
        inputFrames = copy
    }

    /// Opens the copy as the open panel would, and stops there: the startup questions are the feature's to answer.
    private func openCopiedSequence(askingTheStartupQuestions: Bool = true) throws {
        guard let copy = sequenceCopy else { throw RunnerError("\"a fresh copy of the sequence\" has not run") }
        try launch(arguments: ["-StarUITestOpenSequence", copy.path] + (askingTheStartupQuestions ? [] : ["-StarUITestSkipStartupQuestions", "YES"]))
    }

    /// Clicks the control once it can be hit: a control that is there for a moment while a screen is still being put up (the startup questions
    /// come up over the loading view) is not one to click, and a click on one that has gone fails the whole test.
    private func clickId(_ identifier: String) throws {
        let e = element(identifier)
        try waitFor("\(identifier) to be clickable", timeout: 60, detail: { "\n\(self.app.debugDescription)" }) { e.exists && e.isHittable }
        // ...and one that is still moving into place takes a click that is lost: wait until its frame has stopped changing
        var frame = e.frame
        var steady = 0
        while steady < 2 {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.4)
            let now = e.frame
            steady = now == frame ? steady + 1 : 0
            frame = now
        }
        e.click()
    }

    private func expectShown(_ identifier: String, shown: Bool) throws {
        if shown {
            guard element(identifier).waitForExistence(timeout: 60) else {
                throw RunnerError("\(identifier) is not shown\n\(app.debugDescription)")
            }
        } else {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element(identifier))
            guard XCTWaiter.wait(for: [gone], timeout: 30) == .completed else {
                throw RunnerError("\(identifier) is still shown\n\(app.debugDescription)")
            }
        }
    }

    private func expectSelected(_ identifier: String, selected: Bool) throws {
        try expectShown(identifier, shown: true)
        let e = element(identifier)
        try waitFor("\(identifier) \(selected ? "selected" : "not selected")", timeout: 20, detail: { "(isSelected \(e.isSelected))" }) { e.isSelected == selected }
    }

    /// The language a @ui feature runs in: English, unless it says `the language is "<code>"` (`STAR_LANG`).
    private var language: String {
        feature?.steps.first { $0.action == .languageIs }?.args.first ?? "en"
    }

    /// The text of a catalogue key in the feature's language: what the app shows for it.
    private func english(_ key: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("StarCore/Sources/StarCore/Resources/Localizations/\(language).json")
        guard let table = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String], let text = table[key] else {
            throw RunnerError("\(key) is not in the \(language) catalogue")
        }
        return text
    }

    /// The element's text is exactly [text] (English: the runs of a @ui feature are in English).
    /// Clicks the field (which opens a tap-to-edit one), replaces what it holds with [text] and leaves it focused, as a user does before pressing Return.
    private func typeInto(_ text: String, into identifier: String) throws {
        try clickId(identifier)
        app.typeKey("a", modifierFlags: .command)
        app.typeText(text)
    }

    /// The control has the keyboard (a text field being typed into), or not.
    private func expectFocus(_ identifier: String, focused: Bool) throws {
        try expectShown(identifier, shown: true)
        let e = element(identifier)
        // `hasKeyboardFocus` is the attribute the accessibility API reports for it; XCUIElement has no public property on macOS.
        func hasKeyboard() -> Bool { (e.value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
        try waitFor("\(identifier) \(focused ? "to have" : "not to have") the keyboard", timeout: 20, detail: { "(hasKeyboardFocus: \(hasKeyboard()))" }) { hasKeyboard() == focused }
    }

    /// The first whole number in the control's text is [number]: "7" in an open field, "merge with 7 static neighbors" in one that is not.
    private func expectHolds(_ identifier: String, number: Int) throws {
        try expectShown(identifier, shown: true)
        let e = element(identifier)
        func texts() -> [String] { [e.label, e.title, (e.value as? String) ?? ""] }
        func firstNumber(_ text: String) -> Int? { text.range(of: "[0-9]+", options: .regularExpression).flatMap { Int(text[$0]) } }
        try waitFor("\(identifier) to hold \(number)", timeout: 20, detail: { "(it says \(texts()))" }) { texts().contains { firstNumber($0) == number } }
    }

    private func expectSays(_ identifier: String, text expected: String) throws {
        try expectShown(identifier, shown: true)
        let e = element(identifier)
        func texts() -> [String] { [e.label, e.title, (e.value as? String) ?? ""] }
        try waitFor("\(identifier) to say \"\(expected)\"", timeout: 20, detail: { "(it says \(texts()))" }) { texts().contains(expected) }
    }

    /// The element's text is the catalogue's text for [key].
    private func expectReads(_ identifier: String, key: String) throws {
        try expectShown(identifier, shown: true)
        let expected = try english(key)
        let e = element(identifier)
        func texts() -> [String] { [e.label, e.title, (e.value as? String) ?? ""] }
        try waitFor("\(identifier) to read \"\(expected)\"", timeout: 20, detail: { "(it reads \(texts()))" }) { texts().contains(expected) }
    }

    // MARK: menus, windows and preferences

    /// The command's menu title and item label, in English: from `gherkin/ui/commands.json` and the catalogue.
    private func menuItem(_ command: String) throws -> (menu: String, label: String) {
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/commands.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let commands = object["commands"] as? [[String: String]], let entry = commands.first(where: { $0["id"] == command }),
              let menus = object["menus"] as? [String: String], let titleKey = entry["menu"].flatMap({ menus[$0] }), let labelKey = entry["label"] else {
            throw RunnerError("\(command) is not a command of gherkin/ui/commands.json")
        }
        return (try english(titleKey), try english(labelKey))
    }

    /// The work-in-progress question, if it comes up within a few seconds: its red button is pressed. Not being asked is fine: whether a close right after
    /// an edit has anything left to wait for is the app's own business.
    private func confirmClosingIfAsked() throws {
        if element("closeconfirm.confirm").waitForExistence(timeout: 6) { try clickId("closeconfirm.confirm") }
    }

    /// The config.json of the processed copy the feature opens.
    private var processedConfig: URL?

    /// A relocated copy, in the scratch directory, of the processed sequence the cli made once (`gherkin/ui/make-processed-fixture.sh`: it runs the
    /// cli over the sequence the first time it is asked, which takes minutes, and finds it afterwards). The copy's files that hold the old
    /// absolute path (the config.json among them) are rewritten to hold the new one.
    private func makeProcessedCopy() throws {
        let given = try param("sequence")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        let script = Self.repoRoot.appendingPathComponent("gherkin/ui/make-processed-fixture.sh")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let errorLog = scratch.appendingPathComponent("processed-fixture.log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, source.path]
        // A machine without a built cli builds it (the script's STAR_CLI_BUILD): the first feature of a run that needs the processed sequence waits for that.
        process.environment = ProcessInfo.processInfo.environment.merging(["STAR_CLI_BUILD": "1"]) { current, _ in current }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = try FileHandle(forWritingTo: errorLog)
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunnerError("could not make the processed sequence:\n" + ((try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""))
        }
        guard let printed = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).last.map({ $0.trimmingCharacters(in: .whitespaces) }), !printed.isEmpty else {
            throw RunnerError("the processed-fixture script printed no directory")
        }
        let target = scratch.appendingPathComponent("processed")
        try FileManager.default.copyItem(atPath: printed, toPath: target.path)
        if let files = FileManager.default.enumerator(at: target, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in files where url.pathExtension == "json" {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 8_000_000, let text = try? String(contentsOf: url, encoding: .utf8), text.contains(printed) else { continue }
                try text.replacingOccurrences(of: printed, with: target.path).write(to: url, atomically: true, encoding: .utf8)
            }
        }
        processedConfig = target.appendingPathComponent("input/star_temp_\(source.lastPathComponent)/config.json")
    }

    /// Opens the processed copy as Load Config does, with the views a test finds one outlier group by labelled.
    private func openProcessedCopy() throws {
        guard let config = processedConfig else { throw RunnerError("\"a processed copy of the sequence\" has not run") }
        try launch(arguments: ["-StarUITestOpenConfig", config.path, "-StarUITestProbes", "YES"])
    }

    /// The menu's title in the feature's language: from `gherkin/ui/commands.json` (`menus`) and the catalogue.
    private func menuTitle(_ menu: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("gherkin/ui/commands.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let menus = object["menus"] as? [String: String], let titleKey = menus[menu] else {
            throw RunnerError("\(menu) is not a menu of gherkin/ui/commands.json")
        }
        return try english(titleKey)
    }

    /// The menu is in the menu bar, or not (the gui builds Actions and Tools for a sequence and has neither without one).
    private func expectMenu(_ menu: String, there: Bool) throws {
        let title = try menuTitle(menu)
        try waitFor("the \"\(title)\" menu to be \(there ? "in" : "out of") the menu bar", timeout: 20, interval: 1) {
            app.menuBars.menuBarItems[title].exists == there
        }
    }

    private func chooseMenuCommand(_ command: String) throws {
        let item = try menuItem(command)
        app.menuBars.menuBarItems[item.menu].click()
        let entry = app.menuBars.menuItems[item.label]
        guard entry.waitForExistence(timeout: 10) else { throw RunnerError("no menu item \"\(item.label)\" in \"\(item.menu)\"") }
        guard entry.isEnabled else {
            app.typeKey(.escape, modifierFlags: [])
            throw RunnerError("\"\(item.label)\" is disabled")
        }
        entry.click()
    }

    private func expectMenuCommand(_ command: String, enabled: Bool) throws {
        let item = try menuItem(command)
        app.menuBars.menuBarItems[item.menu].click()
        let entry = app.menuBars.menuItems[item.label]
        defer { app.typeKey(.escape, modifierFlags: []) }
        guard entry.waitForExistence(timeout: 10) else { throw RunnerError("no menu item \"\(item.label)\" in \"\(item.menu)\"") }
        guard entry.isEnabled == enabled else { throw RunnerError("\"\(item.label)\" is \(entry.isEnabled ? "enabled" : "disabled"), not \(enabled ? "enabled" : "disabled")") }
    }

    /// What the secondary windows' titles look like: the exact titles, and the beginnings of the ones that carry a number.
    private func windowTitles(_ name: String) throws -> (exact: [String], prefixes: [String]) {
        switch name {
        case "debug": return ([try english("ui.star_debug")], [])
        case "outlier":
            // the window sets its own title (its view's, not the scene's): the generic one until it lists a frame, then "Outliers for frame N"
            let forFrame = try english("ui.outliers_for_frame")
            return ([try english("ui.outlier_group_information")], [String(forFrame.prefix { $0 != "{" })])
        default: throw RunnerError("no window called \"\(name)\" (debug, outlier)")
        }
    }

    private func expectWindow(_ name: String, open: Bool) throws {
        let (titles, prefixes) = try windowTitles(name)
        func count() -> Int {
            app.windows.allElementsBoundByIndex.filter { w in titles.contains(w.title) || prefixes.contains { w.title.hasPrefix($0) } }.count
        }
        try waitFor("the \(name) window to be \(open ? "open" : "closed")", timeout: 15,
                    detail: { "(windows: \(self.app.windows.allElementsBoundByIndex.map { $0.title }))" }) { count() == (open ? 1 : 0) }
    }

    private var preferencesFile: URL { scratch.appendingPathComponent("home/.star.userprefs.json") }

    /// `n` recently opened sequences in the preferences the app will start from (each a config.json that exists: one that does not is dropped).
    private func seedRecents(_ n: Int) throws {
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("home"), withIntermediateDirectories: true)
        var entries: [String: Double] = [:]
        for i in 1...max(n, 1) where i <= n {
            let dir = scratch.appendingPathComponent("recent\(i)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = dir.appendingPathComponent("config.json")
            try "{}".write(to: config, atomically: true, encoding: .utf8)
            entries[config.path] = Double(10 * i)
        }
        try JSONSerialization.data(withJSONObject: ["recentlyOpenedSequencelist": entries]).write(to: preferencesFile)
    }

    /// The bytes of a file of `gherkin/ui/fixtures/prefs/`.
    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot.appendingPathComponent("gherkin/ui/fixtures/prefs/\(name).json"))
    }

    /// The preferences the app will start from are this file, as it is.
    private func seedPreferences(fixture: String) throws {
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("home"), withIntermediateDirectories: true)
        try fixtureData(fixture).write(to: preferencesFile)
    }

    /// The file has not been touched for a few seconds, which is longer than the app takes to write one it means to write.
    private func expectPreferencesUnchanged(fixture: String) throws {
        let expected = try fixtureData(fixture)
        let deadline = Date().addingTimeInterval(4)
        repeat {
            guard let now = try? Data(contentsOf: preferencesFile), now == expected else {
                throw RunnerError("the preferences file is not the fixture \"\(fixture)\" any more")
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
    }

    private func expectPreferencesKey(_ key: String) throws {
        func has() -> Bool {
            guard let data = try? Data(contentsOf: preferencesFile),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return object[key] != nil
        }
        try waitFor("the preferences file to have the key \"\(key)\"", timeout: 15) { has() }
    }

    private func expectUndecodableCopy(fixture: String) throws {
        let copy = URL(fileURLWithPath: preferencesFile.path + ".undecodable")
        let expected = try fixtureData(fixture)
        try waitFor("a copy of the unreadable preferences file beside it", timeout: 15) { (try? Data(contentsOf: copy)) == expected }
    }

    private func recentCount() -> Int? {
        guard let data = try? Data(contentsOf: preferencesFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((object["recentlyOpenedSequencelist"] as? [String: Any]) ?? [:]).count
    }

    private func expectRecents(_ n: Int) throws {
        try waitFor("the preferences file to list \(n) recent sequences", timeout: 15, detail: { "(it lists \(String(describing: self.recentCount())))" }) { recentCount() == n }
    }

    /// A switch or check box: its value is 1 when it is on.
    private func expectOn(_ identifier: String, on: Bool) throws {
        try expectShown(identifier, shown: true)
        let e = element(identifier)
        func isOn() -> Bool {
            if let v = e.value as? String { return v == "1" || v.lowercased() == "on" || v.lowercased() == "true" }
            if let v = e.value as? Int { return v == 1 }
            if let v = e.value as? Bool { return v }
            return false
        }
        try waitFor("\(identifier) \(on ? "on" : "off")", timeout: 20, detail: { "(value \(String(describing: e.value)))" }) { isOn() == on }
    }

    /// `return`, `escape`, `tab`, `space`, an arrow, or one character, with modifiers before it: `cmd+w`, `shift+cmd+,`.
    private func press(_ spec: String) throws {
        let parts = spec.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !name.isEmpty else { throw RunnerError("\"\(spec)\" is not a key") }
        var flags: XCUIElement.KeyModifierFlags = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: throw RunnerError("\"\(m)\" is not a modifier (in \"\(spec)\")")
            }
        }
        switch name {
        case "return", "enter": app.typeKey(.return, modifierFlags: flags)
        case "escape", "esc": app.typeKey(.escape, modifierFlags: flags)
        case "tab": app.typeKey(.tab, modifierFlags: flags)
        case "space": app.typeKey(" ", modifierFlags: flags)
        case "left": app.typeKey(.leftArrow, modifierFlags: flags)
        case "right": app.typeKey(.rightArrow, modifierFlags: flags)
        case "up": app.typeKey(.upArrow, modifierFlags: flags)
        case "down": app.typeKey(.downArrow, modifierFlags: flags)
        default:
            guard name.count == 1 else { throw RunnerError("\"\(name)\" is not a key I know (in \"\(spec)\")") }
            app.typeKey(name, modifierFlags: flags)
        }
    }

    /// Copies the sequence into a fresh temp dir (star derives its temp and output paths from the input
    /// directory's name), then launches the app on the copy and waits for the sequence screen.
    private func openSequence() throws {
        _ = try requireSettings()
        let given = try param("sequence")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else {
            throw RunnerError("sequence directory not found: \(source.path)")
        }
        let copy = scratch.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        sequenceCopy = copy
        inputFrames = copy
        try launch(arguments: ["-StarUITestOpenSequence", copy.path])
        try answerStartupPrompts()
    }

    /// Opens the video through the import sheet (`-StarUITestOpenVideo` raises it as the open panel would), choosing the
    /// frame format the feature asks for.
    private func importVideo(inBackground: Bool = false) throws {
        backgroundImport = inBackground
        _ = try requireSettings()
        let given = try param("video")
        let source = try TestData.resolve(given, cache: dataCache())
            ?? (given.hasPrefix("/") ? URL(fileURLWithPath: given) : Self.repoRoot.appendingPathComponent(given))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else { throw RunnerError("video not found: \(source.path)") }
        let file: URL
        if isDir.boolValue {
            let videos = try FileManager.default.contentsOfDirectory(atPath: source.path).filter {
                ["mov", "mp4", "m4v", "avi", "mkv", "mpg", "mpeg"].contains(($0 as NSString).pathExtension.lowercased())
            }
            guard videos.count == 1 else { throw RunnerError("expected exactly one video in \(source.path), found \(videos)") }
            file = source.appendingPathComponent(videos[0])
        } else {
            file = source
        }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: copy)
        sequenceCopy = copy
        sourceVideo = copy
        // decodeVideo writes <video dir>/<name>/image_%04d.<ext>
        inputFrames = scratch.appendingPathComponent(copy.deletingPathExtension().lastPathComponent)
        try launch(arguments: ["-StarUITestOpenVideo", copy.path])

        let format = try param("frame_format").lowercased()
        let formats = ["tiff16", "tiff8", "jpeg"]
        guard let index = formats.firstIndex(of: format) else { throw RunnerError("{frame_format} must be one of \(formats), not \(format)") }
        guard element("videoimport.import").waitForExistence(timeout: 120) else {
            throw RunnerError("the video import sheet did not appear\n\(app.debugDescription)")
        }
        // A radio group's items do not always expose the identifier of the Text they were made from, so fall back to position.
        let radio = element("videoimport.format.\(format)")
        if radio.exists { radio.click() } else { app.radioGroups.firstMatch.radioButtons.element(boundBy: index).click() }
        // "Extract video in background": on by default for a video any frame of which is cheap to reach (the probe decides), so it is
        // put the way the step asks rather than clicked blindly.
        let background = element("videoimport.background")
        if background.waitForExistence(timeout: 30) {
            let isOn = (background.value as? String) == "1" || (background.value as? Int) == 1
            if isOn != inBackground { background.click() }
        }
        // The sheet now also asks where the working files go, so it is 665pt tall: on a hosted runner's 1024x768 screen its Import button
        // is at y 733-753, in the Dock's zone. A click there raises no error (the point is on the screen) and is lost, and the sheet stays
        // up until the wait for the first startup prompt gives up 600s later. `activateDefault` would click too if the button counts as
        // hittable; Return is Import's default action, the sheet has the keyboard focus, and it does not care where the button is.
        app.typeKey(.return, modifierFlags: [])
        try answerStartupPrompts()
    }

    /// Horizon → camera → (select horizon: No) → what to remove → Start, as a user answers them.
    private func answerStartupPrompts() throws {
        let s = try requireSettings()
        // The sequence screen is up once the first startup question is (decoding a video comes first).
        try tap(s.horizon ? "startup.horizon.yes" : "startup.horizon.no", timeout: 600)
        try tap(s.moving ? "startup.moving.moving" : "startup.moving.static")
        if s.horizon { try tap(s.moving ? "startup.selectmovinghorizons.no" : "startup.selecthorizon.no") }

        // Mode choice defaults to automatic; the auto-selective toggle under it makes it auto selective; the selective row is selective.
        guard element("startup.removal.start").waitForExistence(timeout: 120) else { throw RunnerError("the removal prompt did not appear") }
        switch s.clean {
        case "auto": break
        case "autoSelective": try tap("startup.removal.autoselective")
        case "selective": try tap("startup.removal.selective")
        default: throw RunnerError("unknown clean method \(s.clean)")
        }
    }

    /// Start Processing, "render a video afterwards?" per the feature, then wait for the run (and the render) to finish.
    private func processEveryFrame() throws {
        guard sequenceCopy != nil else { throw RunnerError("neither \"I open the sequence\" nor \"I import the video\" has run") }
        try activateDefault("startup.removal.start")
        // A user who chose "don't ask again" skips this prompt; the run is simply already going then.
        let prompt = rendersVideo ? "prompt.pre.yes" : "prompt.pre.no"
        if element(prompt).waitForExistence(timeout: 30) { element(prompt).click() }

        // XCUITest queries are answered by the app's own main thread, which is the thread the horizon overlays and previews keep busy:
        // measured, the runner's polling was about half of it, and a query that waits too long fails the test. So the long waits watch the
        // disk, and the UI is asked once the disk says the run is over. Auto selective has no such file to watch (its frames wait for
        // review), so it asks the UI, slowly.
        // A video extracted in the background is still arriving: the count to wait for is the whole video's, which its extraction.json
        // says is complete once every frame is out.
        if backgroundImport { try waitForExtraction() }
        let expected = try frameFiles(in: inputFrames).count
        if clean == "autoSelective" { try finishAutoSelective(expected: expected); return }

        let progress = element("processing.progress")
        var last = "(none)"
        try waitFor("processing to finish", timeout: 45 * 60, interval: 5, detail: { "(last progress: \(last))" }) {
            guard let out = try? outputFrames(), ((try? frameFiles(in: out).count) ?? 0) >= expected else { return false }
            // With a render afterwards the render sheet covers the window the moment the run ends, and the progress line is no longer in
            // reach: the frames all being on disk (and still so a poll later) is the end of processing.
            if rendersVideo {
                defer { settledOnce = true }
                if settledOnce { completeFrames = expected }
                return settledOnce
            }
            guard progress.exists else { return false }
            let state = progress.label
            if state != last { print("progress: \(state)") }
            last = state
            let parts = state.split(separator: "/").map(String.init)
            guard parts.count == 3, let complete = Int(parts[0]), let total = Int(parts[1]) else { return false }
            let done = total > 0 && complete == total && parts[2] == "idle"
            if done { completeFrames = complete }
            return done
        }
    }

    /// Auto selective in the GUI writes the final frames by itself, as the cli does, and each frame is complete once its final is written
    /// (L5: it used to stay short of complete, so the progress line never read N/N). The run is still watched on the disk, its outlier data
    /// and then the finals: XCUITest queries are answered by a busy app's main thread and time out.
    private func finishAutoSelective(expected: Int) throws {
        func tempDir() -> URL? {
            (try? FileManager.default.contentsOfDirectory(atPath: scratch.path))?.first { $0.hasPrefix("star_temp_") }
                .map { scratch.appendingPathComponent($0) }
        }
        try waitFor("every frame's outlier data and final image", timeout: 45 * 60, interval: 10) {
            guard let t = tempDir(), let out = try? outputFrames() else { return false }
            return ((try? frameFiles(in: t.appendingPathComponent("auto-selective-processed")).count) ?? 0) >= expected
              && ((try? frameFiles(in: out).count) ?? 0) >= expected
        }
        // let the last frame's write land
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 10)
        completeFrames = expected
    }

    /// Waits until the video's frames are all extracted: the folder's `extraction.json` says `"complete" : true`.
    private func waitForExtraction() throws {
        guard let dir = inputFrames else { return }
        let sidecar = dir.appendingPathComponent("extraction.json")
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            if let data = try? Data(contentsOf: sidecar),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["complete"] as? Bool == true { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw RunnerError("the video's frames were still being extracted after 10 minutes: \(sidecar.path)")
    }

    private func frameFiles(in dir: URL?) throws -> [String] {
        guard let dir else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            !$0.hasPrefix(".") && ["tif", "tiff", "jpg", "jpeg", "png"].contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    /// The video's path, once the render has written it: `<outputPath>/<name>.<container>`, beside the output frames.
    private func renderedVideoFile() throws -> URL? {
        let base = try outputFrames().lastPathComponent
        return try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .first { $0.hasPrefix(base) && ["mov", "mp4", "mkv", "avi"].contains(($0 as NSString).pathExtension.lowercased()) }
            .map { scratch.appendingPathComponent($0) }
    }

    /// Processing answered Yes to the render prompt, so the render sheet opens and starts by itself with the default settings.
    /// Watched on the disk, like processing: the video exists and has stopped growing.
    private func renderOutputVideoStep() throws {
        guard rendersVideo else { throw RunnerError("the render prompt was answered No") }
        var lastSize = -1
        do {
            try waitFor("the video render to finish", timeout: 10 * 60, interval: 5) {
                guard let video = try? renderedVideoFile(),
                      let size = (try? FileManager.default.attributesOfItem(atPath: video.path))?[.size] as? Int, size > 0 else { return false }
                defer { lastSize = size }
                return size == lastSize
            }
        } catch {
            // The screenshot is the only evidence of what the sheet was showing.
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            testCase.add(shot)
            throw error
        }
    }

    /// Copies the validator's reports and the run's config.json to `$STAR_GHERKIN_ARTIFACTS/<feature>` for CI to upload.
    private func saveArtifacts(of feature: Feature) {
        // Default: the runner's own container tmp (`~/Library/Containers/com.star-guiUITests.xctrunner/Data/tmp/gherkin-artifacts`), the only
        // place a sandboxed runner can write; CI uploads that directory.
        let dir = ProcessInfo.processInfo.environment["STAR_GHERKIN_ARTIFACTS"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("gherkin-artifacts")
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: dir).appendingPathComponent(feature.id)
        // The UI-test runner is sandboxed: it can only write inside its own container, so a directory outside it is skipped, not failed.
        // (CI uploads the container's tmp directory instead; see the workflow.)
        do { try fm.createDirectory(at: dest, withIntermediateDirectories: true) } catch { print("artifacts: cannot write \(dest.path): \(error)"); return }
        for name in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] {
            if name.hasPrefix("report-") { if fm.fileExists(atPath: dest.appendingPathComponent(name).path) { try? fm.removeItem(at: dest.appendingPathComponent(name)) }; try? fm.copyItem(at: scratch.appendingPathComponent(name), to: dest.appendingPathComponent(name)) }
            if name.hasPrefix("star_temp_"), fm.fileExists(atPath: scratch.appendingPathComponent(name).appendingPathComponent("config.json").path) {
                if fm.fileExists(atPath: dest.appendingPathComponent("config.json").path) { try? fm.removeItem(at: dest.appendingPathComponent("config.json")) }
                try? fm.copyItem(at: scratch.appendingPathComponent(name).appendingPathComponent("config.json"), to: dest.appendingPathComponent("config.json"))
            }
        }
    }

    /// The clean method the feature asked for, in the removal verifier's spelling.
    private var cleanMethod: String? {
        switch clean {
        case "auto": return "automatic:false"
        case "autoSelective": return "automatic:true"
        case "selective": return "selective"
        default: return nil
        }
    }

    // MARK: removal checks (star-removal-verify)

    /// Reports and crops go in the scratch directory as `report-removal-*`: the UI-test runner is sandboxed and cannot write into the
    /// repository, and `saveArtifacts` copies every `report-*` entry out to the container's artifacts directory, which CI uploads.
    private func reportsDirectory() -> URL { scratch }

    private func verifierBinary() throws -> URL {
        #if os(Windows)
        let exe = "star-removal-verify.exe"
        #else
        let exe = "star-removal-verify"
        #endif
        // On Windows SwiftPM builds into .build/<triple>/release, so CI sets STAR_REMOVAL_VERIFY; this default is for local runs.
        let path = ProcessInfo.processInfo.environment["STAR_REMOVAL_VERIFY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.repoRoot.appendingPathComponent("trail_tools/.build/release/\(exe)").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw RunnerError("no star-removal-verify at \(path): run `swift build -c release --package-path trail_tools`, or set STAR_REMOVAL_VERIFY")
        }
        return URL(fileURLWithPath: path)
    }

    private func labelsFile() throws -> URL {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        let labels = input.appendingPathComponent("labels.json")
        guard FileManager.default.fileExists(atPath: labels.path) else { throw RunnerError("no labels.json in the sequence: \(labels.path)") }
        return labels
    }

    /// Runs the verifier. A failing exit status fails the step with its summary and the report and crop paths.
    private func runVerifier(_ extra: [String], reportName: String) throws -> [String: Any] {
        guard let input = sequenceCopy else { throw RunnerError("\"I open the sequence\" has not run") }
        guard completeFrames != nil else { throw RunnerError("\"I process every frame\" has not run") }
        let reports = reportsDirectory()
        let crops = reports.appendingPathComponent("report-removal-\(reportName)-crops")
        let report = reports.appendingPathComponent("report-removal-\(reportName).json")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        guard let method = cleanMethod else { throw RunnerError("no clean method step ran before the open step") }

        var args = ["--input", input.path, "--output", try outputFrames().path, "--labels", try labelsFile().path,
                    "--thresholds", Self.repoRoot.appendingPathComponent("gherkin/removal-thresholds.json").path,
                    "--clean-method", method, "--dataset", input.lastPathComponent,
                    "--skip-unmeasurable", "--report", report.path, "--crops", crops.path]
        args += extra

        let p = Process()
        p.executableURL = try verifierBinary()
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        print(text.split(separator: "\n").suffix(12).joined(separator: "\n"))
        guard p.terminationStatus == 0 else {
            throw RunnerError("star-removal-verify exited \(p.terminationStatus) for \"\((feature?.id ?? "feature"))\"\n"
                              + text.split(separator: "\n").suffix(30).joined(separator: "\n")
                              + "\nreport: \(report.path)\ncrops: \(crops.path)")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any] else {
            throw RunnerError("unreadable report \(report.path)")
        }
        return json
    }

    private func confirmedObjectCount(trailClass: String) throws -> Int {
        let data = try Data(contentsOf: try labelsFile())
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = root["frames"] as? [String: [[String: Any]]] else { throw RunnerError("labels.json is not a label set") }
        return frames.values.joined().filter { ($0["class"] as? String) == trailClass && ($0["confirmed"] as? Bool) == true }.count
    }

    private func pinCount() throws -> Int {
        let data = try Data(contentsOf: Self.repoRoot.appendingPathComponent("gherkin/removal-pins.json"))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let pins = root["pins"] as? [Any] else {
            throw RunnerError("removal-pins.json is not a pin list")
        }
        return pins.count
    }

    private func trailsRemoved(trailClass: String) throws {
        let expected = try confirmedObjectCount(trailClass: trailClass)
        // Per-object verdicts differ between platforms, and selective leaves most faint labelled streaks alone by design
        // (BUGS.md BUG-004, and the measurements in the result notes). automatic:true is judged by the fraction removed plus
        // pinned objects; the fraction cannot see the 1b2cb327 bug (0.78 broken vs 0.83 fixed), the pins can (43 of 43 come back).
        let pins = ["--pins", Self.repoRoot.appendingPathComponent("gherkin/removal-pins.json").path]
        var extra = ["--expect", "\(trailClass)=removed"]
        switch cleanMethod {
        case "selective": extra += ["--pins-only"] + pins
        case "automatic:true": extra += ["--aggregate"] + pins
        default: break
        }
        let report = try runVerifier(extra, reportName: "\(trailClass)s-removed")
        // not vacuous: the verifier must have looked at every confirmed object of this class
        let summary = report["summary"] as? [String: Any]
        let objects = (summary?["objects"] as? Int) ?? -1
        guard expected > 0 else { throw RunnerError("labels.json has no confirmed \(trailClass) objects: the step would check nothing") }
        guard objects == expected else {
            throw RunnerError("the verifier checked \(objects) \(trailClass) objects, labels.json has \(expected) confirmed: refusing to pass")
        }
        if cleanMethod == "automatic:true" || cleanMethod == "selective" {
            let pinned = try pinCount()
            let checked = (summary?["pinsChecked"] as? Int) ?? -1
            guard checked == pinned else { throw RunnerError("the verifier checked \(checked) pinned objects, removal-pins.json has \(pinned): refusing to pass") }
        }
        let measured = (summary?["passed"] as? Int ?? 0) + (summary?["failed"] as? Int ?? 0)
        guard measured > 0 else { throw RunnerError("no \(trailClass) object was measurable: refusing to pass") }
    }

    private func nothingElseChanged() throws {
        guard cleanMethod == "selective" else { throw RunnerError("\"nothing outside the labelled trails changed\" is only valid with the selective clean method") }
        let report = try runVerifier(["--unchanged-outside"], reportName: "unchanged-outside")
        let frames = (try frameFiles(in: try outputFrames())).count
        let covered = (report["collateral"] as? [String: Any])?.count ?? 0
        guard covered == frames, frames > 0 else { throw RunnerError("the unchanged-outside check covered \(covered) frames, Star wrote \(frames): refusing to pass") }
        guard (report["collateralStatus"] as? String) == "pass" else { throw RunnerError("the unchanged-outside check did not pass (status \(String(describing: report["collateralStatus"])))") }
    }

    private func starsPreserved() throws {
        let report = try runVerifier(["--stars"], reportName: "stars")
        let frames = (try frameFiles(in: try outputFrames())).count
        let stars = (report["stars"] as? [String: Any])?.count ?? 0
        guard stars == frames, frames > 0 else { throw RunnerError("the star check covered \(stars) frames, Star wrote \(frames): refusing to pass") }
    }

    // MARK: validation: removal_tools/star-output-verify, the one tool every client uses

    private func verifyBinary() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["STAR_OUTPUT_VERIFY_PATH"], !p.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: p) else { throw RunnerError("STAR_OUTPUT_VERIFY_PATH is not an executable: \(p)") }
            return URL(fileURLWithPath: p)
        }
        let exe = Self.repoRoot.appendingPathComponent("removal_tools/.build/release/star-output-verify")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw RunnerError("no validator at \(exe.path): run `swift build -c release --package-path removal_tools`, or set STAR_OUTPUT_VERIFY_PATH")
        }
        return exe
    }

    private func verify(_ args: [String]) throws {
        let p = Process()
        p.executableURL = try verifyBinary()
        p.arguments = args + ["--report", scratch.appendingPathComponent("report-\(args[0]).json").path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")
        print(lines.count > 40 ? (lines.prefix(10) + ["…"] + lines.suffix(10)).joined(separator: "\n") : text)
        guard p.terminationStatus == 0 else { throw RunnerError("star-output-verify \(args[0]) failed:\n\(text)") }
    }

    /// The directory processing wrote the final frames to: `<outputPath>/<sequence name>-star-v-<version>`, beside the copy.
    private func outputFrames() throws -> URL {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        // directories only: the rendered video is a sibling with the same prefix
        let outDirs = siblings.filter {
            var isDir: ObjCBool = false
            return $0.hasPrefix("\(input.lastPathComponent)-star-v-")
              && FileManager.default.fileExists(atPath: scratch.appendingPathComponent($0).path, isDirectory: &isDir) && isDir.boolValue
        }
        guard outDirs.count == 1 else { throw RunnerError("expected one output directory in \(scratch.path), found \(siblings)") }
        return scratch.appendingPathComponent(outDirs[0])
    }

    /// The run's saved config.json: in the `star_temp_<name>` directory beside the input, as for the cli.
    private func configJSON() throws -> URL {
        let found = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix("star_temp_") }
            .map { scratch.appendingPathComponent($0).appendingPathComponent("config.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard found.count == 1 else { throw RunnerError("expected one star_temp_*/config.json in \(scratch.path), found \(found.map(\.path))") }
        return found[0]
    }

    private func usedRequestedSettings() throws {
        let s = try requireSettings()
        try verify(["settings", "--config", try configJSON().path, "--horizon", s.horizon ? "yes" : "no",
                    "--camera", s.moving ? "moving" : "static", "--clean", s.clean])
    }

    private func everyFrameOutput() throws {
        guard let input = inputFrames, completeFrames != nil else { throw RunnerError("\"I process every frame\" has not run") }
        var args = ["frames", "--input-dir", input.path, "--output-dir", try outputFrames().path]
        if let v = sourceVideo { args += ["--video", v.path] }
        try verify(args)
    }

    private func outputKeepsFormat() throws {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        try verify(["format", "--input-dir", input.path, "--output-dir", try outputFrames().path])
    }

    private func processedIn(_ mode: String) throws {
        guard let input = inputFrames else { throw RunnerError("nothing has been opened") }
        var args = ["mode", "--mode", mode, "--input-dir", input.path, "--output-dir", try outputFrames().path,
                    "--thresholds", Self.repoRoot.appendingPathComponent("removal_tools/thresholds.json").path]
        if mode == "autoSelective" { args += ["--config", try configJSON().path] }
        if ProcessInfo.processInfo.environment["STAR_GHERKIN_REPORT_ONLY"] != nil { args.append("--report-only") }
        try verify(args)
    }

    private func outputVideoMatches() throws {
        // The video is written beside the output frames, as `<outputPath>/<name>.<container>`, in the imported video's
        // settings, else Config's defaults (ProRes, 30 fps).
        let frames = try outputFrames()
        let base = frames.lastPathComponent
        let candidates = try FileManager.default.contentsOfDirectory(atPath: scratch.path).filter {
            $0.hasPrefix(base) && ["mov", "mp4", "mkv", "avi"].contains(($0 as NSString).pathExtension.lowercased())
        }
        guard candidates.count == 1 else { throw RunnerError("expected one rendered video named \(base).* in \(scratch.path), found \(candidates)") }
        try verify(["video", "--video", scratch.appendingPathComponent(candidates[0]).path, "--output-dir", frames.path,
                    "--frame-rate", "30/1", "--codec", sourceVideo == nil ? "prores" : "h264"])
    }

    /// Star's critical warnings are alerts: none may be on screen at the end.
    private func noProblems() throws {
        XCTAssertFalse(app.alerts.firstMatch.exists, "an alert is on screen: \(app.alerts.firstMatch.debugDescription)")
    }
}
