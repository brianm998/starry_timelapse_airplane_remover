import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

class ViewModel: ObservableObject {
    var config: Config?
    var framesToCheck: FramesToCheck
    var eraser: NighttimeAirplaneRemover?
    var frameSaveQueue: FrameSaveQueue?
    var frame: FrameAirplaneRemover? {
        didSet {
            if let frame = frame {
                let new_frame_width = CGFloat(frame.width)
                let new_frame_height = CGFloat(frame.height)
                if frame_width != new_frame_width {
                    frame_width = new_frame_width
                }
                if frame_height != new_frame_height {
                    frame_height = new_frame_height
                }
                //Log.w("INITIAL SIZE [\(frame_width), \(frame_height)]")
            }
        }
    }
    var outlierViews: [OutlierGroupView] = []
    var outlierCount: Int = 0
    var image: Image?
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
        if framesToCheck.isDone() {
            frame = nil
            outlierViews = []
            image = Image(systemName: "globe").resizable()
        }
        if let frame = frame {
            let frameView = framesToCheck.frames[frame.frame_index]
            
            outlierViews = frameView.outlierViews
            //Log.i("we have \(outlierViews.count) outlierGroups")
        }
        outlierCount = outlierViews.count

        self.objectWillChange.send()
    }
}
