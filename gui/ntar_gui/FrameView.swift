
import Foundation
import SwiftUI
import Cocoa
import NtarCore


// UI view class used for each frame
class FrameView: ObservableObject {
    init(_ frame_index: Int) {
        self.frame_index = frame_index
    }
    
    let frame_index: Int
    var frame: FrameAirplaneRemover?
    @Published var outlierViews: [OutlierGroupView] = []
    @Published var image: Image?
    @Published var thumbnail_image: Image? 
    @Published var preview_image: Image? 
}

