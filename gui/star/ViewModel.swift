import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable
import logging

// the overall view model
@MainActor @Observable
public final class ViewModel {

    var userPreferences: UserPreferences = UserPreferences()

    init() {
        if let newPrefs = UserPreferences.initialize() {
            userPreferences = newPrefs
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
    var loadingImageSequenceFilename: String?

    var amountLoaded = 0.0
    var numberLoaded = 0
    var numberPreviewsSaved = 0
    var amountPreviewsSaved = 0.0

    //var backgroundColor = Color(red: 0.4, green: 0.4, blue: 0.4)
    var backgroundColor = ViewModel.defaultBackgroundColor

    static let defaultBackgroundColor = Color(red: 0.1, green: 0.1, blue: 0.1)

    //var backgroundColor: Color = .gray
    //var backgroundColor: Color = .black

    var imageSequence: ImageSequenceViewModel?

    var eraserTask: Task<(),Never>?
    
    // prepare for another sequence
    func unloadSequence() {
        imageSequence = nil
    }

    func startup(withConfigFile jsonConfigFilename: String) async throws {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = jsonConfigFilename
        imageSequence = try await ImageSequenceViewModel(withConfig: jsonConfigFilename) { numberPreviewsSaved, amountPreviewsSaved, numberLoaded, amountLoaded in
            Task { @MainActor in
                self.amountLoaded = amountLoaded
                self.numberLoaded = numberLoaded
                self.numberPreviewsSaved = numberPreviewsSaved
                self.amountPreviewsSaved = amountPreviewsSaved
            }
        }
        isLoadingImageSequence = false
        loadingImageSequenceFilename = nil
        numberLoaded = 0
        amountLoaded = 0.0
        numberPreviewsSaved = 0
        amountPreviewsSaved = 0.0

        self.userPreferences.justOpened(filename: jsonConfigFilename) // make sure this works
    }

    func startup(withConfig config: ConfigManager) async throws {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = await config.config().imageSequenceDirname
        imageSequence = try await ImageSequenceViewModel(with: config) { numberPreviewsSaved, amountPreviewsSaved, numberLoaded, amountLoaded in
            Task { @MainActor in
                self.amountLoaded = amountLoaded
                self.numberLoaded = numberLoaded
                self.numberPreviewsSaved = numberPreviewsSaved
                self.amountPreviewsSaved = amountPreviewsSaved
            }
        }
        loadingImageSequenceFilename = nil
        isLoadingImageSequence = false
        numberLoaded = 0
        amountLoaded = 0.0
        numberPreviewsSaved = 0
        amountPreviewsSaved = 0.0

        // just opened handled in InitialView where we know the full path
    }

    func startup(withNewImageSequence imageSequenceDirname: String) async throws {
        isLoadingImageSequence = true
        loadingImageSequenceFilename = imageSequenceDirname

        // XXX check to see if we should create previews here
        
        imageSequence = try await ImageSequenceViewModel(withNewImageSequence: imageSequenceDirname) { numberPreviewsSaved, amountPreviewsSaved, numberLoaded, amountLoaded in
            Task { @MainActor in
                self.amountLoaded = amountLoaded
                self.numberLoaded = numberLoaded
                self.numberPreviewsSaved = numberPreviewsSaved
                self.amountPreviewsSaved = amountPreviewsSaved
            }
        }
        isLoadingImageSequence = false
        loadingImageSequenceFilename = nil
        numberLoaded = 0
        amountLoaded = 0.0
        numberPreviewsSaved = 0
        amountPreviewsSaved = 0.0

        if let configManager = imageSequence?.config {
            let config = await configManager.config()
            configManager.save()
            self.userPreferences.justOpened(filename: "\(config.outputPath)/\(configManager.jsonFilename())")
        }
    }
}


