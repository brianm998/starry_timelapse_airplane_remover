
import Foundation
import SwiftUI
import Cocoa
import NtarCore


// UI view class used for each frame
class FrameView: ObservableObject {
    init(_ frame_index: Int) {
        self.frame_index = frame_index
    }

    var isCurrentFrame: Bool = false
    
    let frame_index: Int
    var frame: FrameAirplaneRemover? {
        didSet {
            Log.d("frame \(frame_index) set frame to \(frame)")
        }
    }
    @Published var outlierViews: [OutlierGroupView] = []

    // we don't keep full resolution images here
    
    @Published var thumbnail_image: Image = initial_image
    @Published var preview_image: Image = initial_image
    @Published var processed_preview_image: Image = initial_image
    @Published var test_paint_preview_image: Image = initial_image
}

fileprivate let initial_image = Image(systemName: "rectangle.fill").resizable()
