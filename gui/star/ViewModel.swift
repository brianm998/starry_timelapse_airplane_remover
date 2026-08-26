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

    /// A view onto the one live copy, not a copy of it — see `UserPreferencesStore`.
    var userPreferences: UserPreferences {
        get { UserPreferencesStore.shared.preferences }
        set { UserPreferencesStore.shared.preferences = newValue }
    }

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

    /// The most recent `StarWarning` of any severity, whether or not it was shown anywhere.
    /// The banner below is what the user actually sees for the ones that do not interrupt.
    var latestWarning: StarWarning?

    var showWarningAlert = false
    var warningTitle: String = ""
    var warningMessage: String = ""
    var warningSuggestion: String?

    /// The message and the suggestion as one block of text, for the system alert — which
    /// takes a single body string.  The suggestion gets its own paragraph because, unlike
    /// an error, there is usually something the user can actually do about it.
    var warningAlertText: String {
        guard let warningSuggestion else { return warningMessage }
        return "\(warningMessage)\n\n\(warningSuggestion)"
    }

    /// What the alert currently on screen is about, so acknowledging it silences that
    /// condition rather than whatever happened to be reported since.
    private var alertingWarningKind: StarWarning.Kind?

    /// Conditions the user has already been interrupted about and dismissed.
    ///
    /// These conditions are sampled for as long as they last, and `StarWarnings` re-delivers
    /// the same kind every 30 seconds, so without this the modal comes straight back after
    /// the user presses OK.  Saying it once is the whole of what a modal can usefully do; a
    /// repeat goes to the banner, the log and the run marker instead.
    private var acknowledgedWarningKinds: Set<StarWarning.Kind> = []

    // MARK: - the banner

    /// The warning the banner is showing, if any.
    ///
    /// The banner is where every warning that deliberately did *not* interrupt goes: the
    /// `warning`-severity ones, and repeats of a `critical` condition the user has already
    /// acknowledged.  Without it those only reached the log, which in a gui means nobody sees
    /// them — the whole point of a severity that does not interrupt is that there is somewhere
    /// quieter for it to go.
    private(set) var bannerWarning: StarWarning?

    /// How long the banner stays up for a condition that passes on its own.
    ///
    /// Longer than the 30 seconds `StarWarnings` waits before re-delivering the same kind, so
    /// a condition that is still happening keeps the banner alive and one that has stopped
    /// takes it down shortly afterwards.  A property rather than a constant so tests do not
    /// have to wait a minute.
    var bannerLifetime: TimeInterval = 60

    private var bannerExpiry: Task<Void, Never>?

    /// Show a warning in the banner, replacing whatever was there.
    ///
    /// The newest report wins: these arrive at most every 30 seconds per kind, and a banner
    /// that queued them would be showing the user a condition from several minutes ago.
    private func show(inBanner warning: StarWarning) {
        bannerWarning = warning
        bannerExpiry?.cancel()
        bannerExpiry = nil

        // A fact about the run — output that could not be written, a disk that will run out —
        // stays until the user takes it down.  It does not stop being true, and it is posted
        // once, so a banner that expired could take it away before anyone read it.
        guard warning.describesAPassingCondition, bannerLifetime > 0 else { return }

        let lifetime = bannerLifetime
        bannerExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, self.bannerWarning?.time == warning.time else { return }
            self.bannerWarning = nil
            self.bannerExpiry = nil
        }
    }

    /// The banner's Dismiss button.
    func dismissBanner() {
        bannerExpiry?.cancel()
        bannerExpiry = nil
        bannerWarning = nil
    }

    /// Route a warning to the user.
    ///
    /// Only `critical` interrupts.  A `warning` — star pausing work because the machine is
    /// busy, or the system asking for memory back — is something the user may want to know
    /// but does not need to act on, and a modal for it would train them to dismiss the modal
    /// that matters, so it goes to the banner instead.  The critical ones are memory pressure
    /// at the level where the system is about to start killing processes, and the report of a
    /// previous run that was killed.
    func report(warning: StarWarning) {
        self.latestWarning = warning
        guard warning.severity == .critical else {
            show(inBanner: warning)
            return
        }
        guard !acknowledgedWarningKinds.contains(warning.kind) else {
            Log.i("not interrupting again for \(warning.kind.rawValue): already acknowledged")
            // Still worth saying, quietly: the condition the user acknowledged is happening
            // again, or still happening.
            show(inBanner: warning)
            return
        }
        self.warningTitle = warning.title
        self.warningMessage = warning.message
        self.warningSuggestion = warning.suggestion
        self.alertingWarningKind = warning.kind
        self.showWarningAlert = true
    }

    /// The alert's OK button.  Closes it, and remembers the condition so the same one cannot
    /// put the same alert straight back up.
    ///
    /// Deliberately does not leave the same warning behind in the banner: the user has just
    /// read it and said so, and making them dismiss the same sentence twice is how a banner
    /// becomes something to click past.  A *later* report of the condition does go there.
    func acknowledgeWarning() {
        self.showWarningAlert = false
        if let kind = alertingWarningKind {
            acknowledgedWarningKinds.insert(kind)
            alertingWarningKind = nil
        }
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
        // A condition the user acknowledged about the sequence they just closed should not
        // stay acknowledged for the next one, and a banner about it should not still be up.
        acknowledgedWarningKinds = []
        alertingWarningKind = nil
        dismissBanner()
    }

    /// Open a sequence from a config file star wrote on an earlier run — Load Config, Open
    /// Recent, or a dropped `.json`.
    ///
    /// This and `startup(withConfig:)` are the two ways a sequence is *re*-opened, and both
    /// raise the progress panel: the config already carries the answers the startup
    /// questionnaire asks for, so what there is left to tell the user is how far the last
    /// run got and what to do about it.  `startup(withNewImageSequence:)` deliberately does
    /// not — it builds a fresh config, so it has those questions to ask instead.
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
        imageSequenceViewModel.applyUserPreferences()
        imageSequenceViewModel.sequenceProgressModalShowing = true
        isLoadingImageSequence = false
        loadingImageSequenceFilename = nil
        self.userPreferences.justOpened(filename: jsonConfigFilename)
    }

    /// Open a sequence from a config file that has already been parsed.  See
    /// `startup(withConfigFile:)` for why this raises the progress panel too.
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
        imageSequenceViewModel.applyUserPreferences()
        imageSequenceViewModel.sequenceProgressModalShowing = true
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
        imageSequenceViewModel.applyUserPreferences()
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


