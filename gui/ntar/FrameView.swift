
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

    // optional to distinguish between not loaded and empty list
    @Published var outlierViews: [OutlierGroupView]?

    // we don't keep full resolution images here
    
    @Published var thumbnail_image: Image = initial_image
    @Published var preview_image: Image = initial_image
    @Published var processed_preview_image: Image = initial_image
    @Published var test_paint_preview_image: Image = initial_image

    // this does a view layer only translation so that we don't have
    // to wait for the longer running background process to update the view
    public func userSelectAllOutliers(toShouldPaint should_paint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint) 
    {
        // first get bounding box from start and end location
        var min_x: CGFloat = CGFLOAT_MAX
        var max_x: CGFloat = 0
        var min_y: CGFloat = CGFLOAT_MAX
        var max_y: CGFloat = 0

        if startLocation.x < min_x { min_x = startLocation.x }
        if startLocation.x > max_x { max_x = startLocation.x }
        if startLocation.y < min_y { min_y = startLocation.y }
        if startLocation.y > max_y { max_y = startLocation.y }
        
        if endLocation.x < min_x { min_x = endLocation.x }
        if endLocation.x > max_x { max_x = endLocation.x }
        if endLocation.y < min_y { min_y = endLocation.y }
        if endLocation.y > max_y { max_y = endLocation.y }

        let gesture_bounds = BoundingBox(min: Coord(x: Int(min_x), y: Int(min_y)),
                                         max: Coord(x: Int(max_x), y: Int(max_y)))
        
        outlierViews?.forEach() { group in
            if gesture_bounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change paint status

                group.group.shouldPaint = .userSelected(should_paint)
            }
            
        }
    }
}

fileprivate let initial_image = Image(systemName: "rectangle.fill").resizable()
