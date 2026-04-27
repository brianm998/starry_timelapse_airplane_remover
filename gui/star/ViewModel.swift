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
    
    var showInfoDialog = false
    var currentInfoType: InfoType = .about

    var labelText: String = "Started"

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


