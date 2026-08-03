import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging


enum CursorStackItem {
    case literal(NSCursor)
    case method(() -> NSCursor)
}

@MainActor @Observable
public final class LoggingViewModel {
    var logs: [GUILogHandler.LogLine] = [] {
        didSet {
            if logs.count > maxGUILogLines {
                logs = Array(logs.suffix(maxGUILogLines))
            }
        }
    }

    var maxGUILogLines = 1000 // guess
    var maxGUILogLinesString = "100000" // guess
    
    // level for what is shown in the gui
    var level: Log.Level = .info

    var fileLogEnabled = false
    // level for what is written to file
    var fileLogLevel: Log.Level = .info
    
    func clearLogs() { logs = [] }

    // all current logs as one log per line in a big string
    var rawLogs: String {
        var ret: String = ""
        for log in logs {
            ret += log.logLine
            ret += "\n"
        }
        return ret
    }
}

// the overall view model
@MainActor @Observable
public final class ViewModel {

    var userPreferences: UserPreferences = UserPreferences()

    /// The language every window is currently drawn in.
    ///
    /// Observable so that changing it redraws the UI immediately, with no relaunch. The
    /// strings themselves come from `localized(...)`, which is a plain function call and so
    /// invisible to SwiftUI's dependency tracking — the window roots hang `.id(languageCode)`
    /// off this instead, which rebuilds them wholesale. Blunt, but a language change is a rare
    /// event and this way no view can forget to observe it.
    var languageCode: String = StarLocalization.shared.currentCode

    /// Every language the Language menu offers.
    var availableLanguages: [StarLanguage] { StarLocalization.shared.languages }

    /// True when the user has not picked a language and star is following the system.
    var isFollowingSystemLanguage: Bool { userPreferences.language == nil }

    /// Switch languages. `nil` means "go back to following the system".
    func setLanguage(_ language: StarLanguage?) {
        userPreferences.language = language?.code     // persists, and sets the override
        languageCode = StarLocalization.shared.currentCode
    }

    init() {
        if let newPrefs = UserPreferences.initialize() {
            userPreferences = newPrefs
        }

        Task.detached {
            if let newRelease = await StarCore.newRelease() {
                Log.i("new release is available: \(newRelease)")
                Task { @MainActor in
                    self.newRelease = newRelease
                    self.newReleaseSheetShowing = true
                }
            }
        }
    }
    
//    @Environment(\.openWindow) private var openWindow
    
    func report(error: String) {
        self.showErrorAlert = true
        self.errorMessage = "\(error)"
    }

    var showErrorAlert = false
    var errorMessage: String = ""

    // MARK: - Machine warnings

    /// The most recent `StarWarning` of any severity, so a status area can show that
    /// something is off without interrupting the user.
    var latestWarning: StarWarning?

    var showWarningAlert = false
    var warningTitle: String = ""
    var warningMessage: String = ""
    var warningSuggestion: String?

    /// Route a warning to the user.
    ///
    /// Only `critical` interrupts.  A `warning` — star pausing work because the machine is
    /// busy — is something the user may want to know but does not need to act on, and a
    /// modal for it would train them to dismiss the modal that matters.  The critical ones
    /// are memory pressure (the last notice before the system kills the app) and the report
    /// of a previous run that was killed.
    func report(warning: StarWarning) {
        self.latestWarning = warning
        guard warning.severity == .critical else { return }
        self.warningTitle = warning.title
        self.warningMessage = warning.message
        self.warningSuggestion = warning.suggestion
        self.showWarningAlert = true
    }

    var showCloseConfirmation = false
    var closeConfirmationMessage: String = ""
    var closeConfirmationAction: (() -> Void)?
    
    var showInfoDialog = false
    var currentInfoType: InfoType = .about

    var labelText: String = localized("ui.started")

    var isLoadingImageSequence = false
    var isProbingImageSequence = false
    var isExtractingImageSequence = false
    var loadingImageSequenceFilename: String?

    var numberLoaded = 0
    var amountLoaded = 0.0      // 0.0...1.0

    var numberExtracted = 0
    var amountExtracted = 0.0 // 0.0...1.0
    
    //var backgroundColor = Color(red: 0.4, green: 0.4, blue: 0.4)
    var backgroundColor = ViewModel.defaultBackgroundColor

    static let defaultBackgroundColor = Color(red: 0.1, green: 0.1, blue: 0.1)

    //var backgroundColor: Color = .gray
    //var backgroundColor: Color = .black

    var imageSequence: ImageSequenceViewModel?

    var eraserTask: Task<(),Never>?
    
    var cursor: NSCursor = .arrow

    var cursorStack: [CursorStackItem] = []

    var newRelease: GitHubRelease? = nil
    var newReleaseSheetShowing = false

    var showUserPreferencesSheet = false

    func pushCursor(_ cursor: NSCursor) {
        cursorStack.append(.literal(cursor))
        self.cursor = cursor
    }

    func pushCursor(_ cursorMethod: @escaping () -> NSCursor) {
        cursorStack.append(.method(cursorMethod))
        self.cursor = cursorMethod()
    }

    // makes sure the showing cursor is still valid after any kind of change happens
    func refreshCursor() {
        if let lastCursor = cursorStack.last {
            switch lastCursor {
            case .literal(let cursor):
                self.cursor = cursor
            case .method(let cursorMethod):
                self.cursor = cursorMethod()
            }
        } else {
            // fallback
            self.cursor = .arrow
        }
    }

    // better to push a method if possible, this assumes
    // that no other view has changed cursor state 
    func replaceCursor(_ cursor: NSCursor) {
        if cursorStack.count > 0 {
            cursorStack.removeLast()
        }
        cursorStack.append(.literal(cursor))
        self.cursor = cursor
    }
    
    func popCursor() {
        if cursorStack.count > 0 {
            cursorStack.removeLast()
        }
        refreshCursor()
    }

    // prepare for another sequence
    func unloadSequence() {
        imageSequence = nil
        cursorStack = []
        cursor = .arrow
        frameGraphViewModel.reset()
    }

    func startup(withConfigFile jsonConfigFilename: String) async throws {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = jsonConfigFilename

        numberLoaded = 0
        amountLoaded = 0.0

        let imageSequenceViewModel = try await ImageSequenceViewModel(
          viewModel: self, 
          withConfig: jsonConfigFilename
        ) { [weak self]
            numberLoaded,
            amountLoaded in
            
            guard let self else { return }
            
            Task { @MainActor in
                if amountLoaded != 0 {
                    self.amountLoaded = amountLoaded
                }
                if numberLoaded != 0 {
                    self.numberLoaded = numberLoaded
                }
            }
        }
        imageSequence = imageSequenceViewModel
        imageSequenceViewModel.userPreferences = userPreferences
        isLoadingImageSequence = false
        loadingImageSequenceFilename = nil
        self.userPreferences.justOpened(filename: jsonConfigFilename)
    }

    func startup(withConfig config: ConfigManager) async throws {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = config.config().imageSequenceDirname

        numberLoaded = 0
        amountLoaded = 0.0
        
        let imageSequenceViewModel = try await ImageSequenceViewModel(
          viewModel: self, 
          with: config
        ) { [weak self] numberLoaded, amountLoaded in
            guard let self else { return }
            Task { @MainActor in
                if amountLoaded != 0 {
                    self.amountLoaded = amountLoaded
                }
                if numberLoaded != 0 {
                    self.numberLoaded = numberLoaded
                }
            }
        }
        imageSequence = imageSequenceViewModel
        imageSequenceViewModel.userPreferences = userPreferences
        loadingImageSequenceFilename = nil
        isLoadingImageSequence = false
        // just opened handled in InitialView where we know the full path
    }

    func startup(withNewImageSequence imageSequenceDirname: String,
                 and videoInfo: VideoInfo? = nil) async throws
    {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = imageSequenceDirname

        // XXX check to see if we should create previews here
        numberLoaded = 0
        amountLoaded = 0.0
        
        let imageSequenceViewModel =
          try await ImageSequenceViewModel(
            viewModel: self, 
            withNewImageSequence: imageSequenceDirname,
            and: videoInfo
          ) { numberLoaded, amountLoaded in
            Task { @MainActor in
                if amountLoaded != 0 {
                    self.amountLoaded = amountLoaded
                }
                if numberLoaded != 0 {
                    self.numberLoaded = numberLoaded
                }
            }
        }
        imageSequence = imageSequenceViewModel
        imageSequenceViewModel.userPreferences = userPreferences
        isLoadingImageSequence = false
        loadingImageSequenceFilename = nil
        if let configManager = imageSequence?.config {
            let config = configManager.config()
            configManager.save()
            self.userPreferences.justOpened(filename: "\(config.tempOutputPath)/\(configManager.jsonFilename())")
        }
    }

    func startup(withVideoToProcess path: String) async throws {
        isLoadingImageSequence = true

        isProbingImageSequence = true
        let (outputDir, videoInfo) = try await Task.detached() {
            try await decodeVideo(named: path) { currentFrame, totalFrames, outputDir in
                Task { @MainActor in
                    self.isExtractingImageSequence = true
                    self.isProbingImageSequence = false
                    self.numberExtracted = currentFrame
                    self.amountExtracted = Double(currentFrame) / Double(totalFrames)

                    // XXX make a preview here
                    /*
                     XXX because have no config,
                         we don't know where the previews and thumbnails should go
                         or what size they should be
                     XXX
                     */
                }
            }
        }.value

        isExtractingImageSequence = false
        
        Log.d("outputDir \(outputDir)")

        try await startup(withNewImageSequence: outputDir, and: videoInfo)
    }
}


