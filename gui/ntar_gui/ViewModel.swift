import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

// the overall view model
class ViewModel: ObservableObject {
    var config: Config?
    var framesToCheck: FramesToCheck // XXX rename this
    var eraser: NighttimeAirplaneRemover?
    var frameSaveQueue: FrameSaveQueue?
    var no_image_explaination_text: String = "Loading..."

    var frame_width: CGFloat = 300
    var frame_height: CGFloat = 300
    
    var label_text: String = "Started"

    var image_sequence_size: Int = 0
    
    init(framesToCheck: FramesToCheck) {
        Log.w("VIEW MODEL INIT")
        self.framesToCheck = framesToCheck
        //self.framesToCheck.viewModel = self
    }
    
    @MainActor func update() {
        self.objectWillChange.send()
    }
}
