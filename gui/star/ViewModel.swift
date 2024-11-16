import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable
import logging

// the overall view model
@MainActor @Observable
public final class ViewModel {
//    var config: Config?

    var userPreferences: UserPreferences = UserPreferences()

    init() {
        if let newPrefs = UserPreferences.initialize() {
            userPreferences = newPrefs
        }
    }

    
//    @Environment(\.openWindow) private var openWindow

    
//    var sequenceLoaded = false
    
    var showErrorAlert = false
    var errorMessage: String = ""
    
    var labelText: String = "Started"

    var isLoadingImageSequence = false

    var amountLoaded = 0.0
    var numberLoaded = 0
    
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
//        self.sequenceLoaded = false
    }

    func startup(withConfig jsonConfigFilename: String) async throws {
        isLoadingImageSequence = true
        imageSequence = try await ImageSequenceViewModel(withConfig: jsonConfigFilename) { numberLoaded, amountLoaded in
            self.amountLoaded = amountLoaded
            self.numberLoaded = numberLoaded
        }
        isLoadingImageSequence = false
        numberLoaded = 0
        amountLoaded = 0.0
        self.userPreferences.justOpened(filename: jsonConfigFilename) // make sure this works
    }

    
    func startup(withNewImageSequence imageSequenceDirname: String) async throws {
        isLoadingImageSequence = true
        imageSequence = try await ImageSequenceViewModel(withNewImageSequence: imageSequenceDirname) { numberLoaded, amountLoaded in
            self.amountLoaded = amountLoaded
            self.numberLoaded = numberLoaded
        }
        isLoadingImageSequence = false
        numberLoaded = 0
        amountLoaded = 0.0
    }
}


