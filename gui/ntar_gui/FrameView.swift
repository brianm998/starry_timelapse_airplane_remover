
import Foundation
import SwiftUI
import Cocoa
import NtarCore


// UI view class used for each frame
class FrameView {
    init(_ frame_index: Int) {
        self.frame_index = frame_index
    }
    
    let frame_index: Int
    var frame: FrameAirplaneRemover?
    var outlierViews: [OutlierGroupView] = []
    var image: Image?
    var thumbnail_image: Image? 
    var preview_image: Image? 
}

