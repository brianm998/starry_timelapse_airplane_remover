
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
    var frame: FrameAirplaneRemover?
    @Published var outlierViews: [OutlierGroupView] = []
    @Published var image: Image? {
        didSet {
            if let image = image {
                // save memory by not keeping the full resolution images in ram constantly
                // maybe instead of a timer keep a pool of some fixed size?
                Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in 
                    Log.d("frame \(self.frame_index) setting image to nil")
                    if self.isCurrentFrame {
                        // refresh the timer recursively
                        self.image = image
                    } else {
                        self.image = nil
                    }
                }
            }
        }
    }
    @Published var thumbnail_image: Image = Image(systemName: "rectangle.fill").resizable()
    @Published var preview_image: Image = Image(systemName: "rectangle.fill").resizable()
}

