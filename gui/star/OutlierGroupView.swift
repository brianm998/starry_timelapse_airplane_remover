import Foundation
import SwiftUI
import Cocoa
import StarCore



class OutlierGroupView: ObservableObject {

    init (group: OutlierGroup,
          name: String,
          bounds: BoundingBox,
          image: NSImage,
          frame_width: Int,
          frame_height: Int)
    {
        self.group = group
        self.name = name
        self.bounds = bounds
        self.image = image
        self.frame_width = frame_width
        self.frame_height = frame_height
    }

    var isSelected = false
    let group: OutlierGroup
    let name: String
    let bounds: BoundingBox
    let image: NSImage
    let frame_width: Int
    let frame_height: Int
}

