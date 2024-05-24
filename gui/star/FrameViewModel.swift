
import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging
import KHTSwift

// UI view class used for each frame
public class FrameViewModel: ObservableObject {
    init(_ frameIndex: Int) {
        self.frameIndex = frameIndex
    }

    var isCurrentFrame: Bool = false
    
    let frameIndex: Int
    var frame: FrameAirplaneRemover? {
        didSet {
            Log.d("frame \(frameIndex) set frame to \(String(describing: frame))")
        }
    }

    var numberOfPositiveOutliers: Int? {
        if let outlierViews = outlierViews {
            var total: Int = 0
            for outlierView in outlierViews {
                if let shouldPaint = outlierView.group.shouldPaint,
                   shouldPaint.willPaint
                {
                    total += 1
                }
            }
            return total
        }
        return nil
    }

    var numberOfNegativeOutliers: Int? {
        Log.d("numberOfNegativeOutliers \(String(describing: outlierViews?.count))")

        if let outlierViews = outlierViews {
            var total: Int = 0
            Log.v("numberOfNegativeOutliers have outlier views")
            for outlierView in outlierViews {
                Log.v("numberOfNegativeOutliers outlier view \(outlierView) \(outlierView.group.id) \(String(describing: outlierView.group.shouldPaint))")
                if let shouldPaint = outlierView.group.shouldPaint,
                   !shouldPaint.willPaint
                {
                    Log.v("increading count")
                    total += 1
                }
            }
            Log.v("numberOfNegativeOutliers \(total)")
            return total
        }
        return nil
    }
    
    var numberOfUndecidedOutliers: Int? {
        if let outlierViews = outlierViews {
            var total: Int = 0
            for outlierView in outlierViews {
                if outlierView.group.shouldPaint == nil {
                    total += 1
                }
            }
            return total
        }
        return nil
    }

    // optional to distinguish between not loaded and empty list
    @Published var outlierViews: [OutlierGroupViewModel]?
    @Published var loadingOutlierViews: Bool = false

    // we don't keep full resolution images here

    @Published var thumbnailImage: Image = initialImage
    @Published var previewImage: Image = initialImage
    @Published var processedPreviewImage: Image = initialImage
    @Published var subtractionPreviewImage: Image = initialImage
    @Published var blobsPreviewImage: Image = initialImage
    @Published var khtbPreviewImage: Image = initialImage
    @Published var absorbedPreviewImage: Image = initialImage
    @Published var rectifiedPreviewImage: Image = initialImage
    @Published var paintMaskPreviewImage: Image = initialImage
    @Published var houghLinesPreviewImage: Image = initialImage
    @Published var validationPreviewImage: Image = initialImage

    public func update() {
        self.objectWillChange.send()
    }
    
    public func updateAllOutlierViews() {
        if let views = self.outlierViews {
            for view in views { view.objectWillChange.send() }
        }
    }

    fileprivate func boundsFromGesture(between startLocation: CGPoint,
                                  and endLocation: CGPoint) -> BoundingBox
    {

        // first get bounding box from start and end location
        var minX: CGFloat = CGFLOAT_MAX
        var maxX: CGFloat = 0
        var minY: CGFloat = CGFLOAT_MAX
        var maxY: CGFloat = 0

        if startLocation.x < minX { minX = startLocation.x }
        if startLocation.x > maxX { maxX = startLocation.x }
        if startLocation.y < minY { minY = startLocation.y }
        if startLocation.y > maxY { maxY = startLocation.y }
        
        if endLocation.x < minX { minX = endLocation.x }
        if endLocation.x > maxX { maxX = endLocation.x }
        if endLocation.y < minY { minY = endLocation.y }
        if endLocation.y > maxY { maxY = endLocation.y }

        return BoundingBox(min: Coord(x: Int(minX), y: Int(minY)),
                           max: Coord(x: Int(maxX), y: Int(maxY)))
        
    }
    
    // this does a view layer only translation so that we don't have
    // to wait for the longer running background process to update the view
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint,
                                      closure: @escaping () -> Void) 
    {
        Task.detached(priority: .userInitiated) {

            var mutableGroupsToUpdate: [OutlierGroupViewModel] = []
            
            let gestureBounds = self.boundsFromGesture(between: startLocation, and: endLocation)
            
            self.outlierViews?.forEach() { group in
                if gestureBounds.contains(other: group.bounds) {
                    // check to make sure this outlier's bounding box is fully contained
                    // otherwise don't change paint status


                    mutableGroupsToUpdate.append(group)
                    
                }
                
            }

            let groupsToUpdate =  mutableGroupsToUpdate
            
            await MainActor.run {
                for group in groupsToUpdate {
                    group.group.shouldPaint = .userSelected(shouldPaint)
                    group.objectWillChange.send()
                }
                closure()
            }
        }
    }

    public func deleteOutliers(between drag_start: CGPoint,
                               and end_location: CGPoint) -> BoundingBox
    {
        let gestureBounds = boundsFromGesture(between: drag_start, and: end_location)

        var newOutlierViews: [OutlierGroupViewModel] = []
        
        outlierViews?.forEach() { group in
            if !gestureBounds.contains(other: group.bounds) {
                newOutlierViews.append(group)
            }
        }
        self.outlierViews = newOutlierViews

        return gestureBounds
    }
}

fileprivate let initialImage = Image(systemName: "rectangle.fill").resizable()
