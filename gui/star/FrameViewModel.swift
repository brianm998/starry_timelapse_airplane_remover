
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
        Log.i("numberOfNegativeOutliers \(String(describing: outlierViews))")

        if let outlierViews = outlierViews {
            var total: Int = 0
            Log.v("numberOfNegativeOutliers have outlier views")
            for outlierView in outlierViews {
                Log.v("numberOfNegativeOutliers outlier view \(outlierView) \(outlierView.group.name) \(String(describing: outlierView.group.shouldPaint))")
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

    @Published var thumbnailImage: URL?
    @Published var previewImage: URL?
    @Published var processedPreviewImage: URL?
    @Published var subtractionPreviewImage: URL?
    @Published var blobsPreviewImage: URL?
    @Published var khtbPreviewImage: URL?
    @Published var absorbedPreviewImage: URL?
    @Published var rectifiedPreviewImage: URL?
    @Published var paintMaskPreviewImage: URL?
    @Published var houghLinesPreviewImage: URL?
    @Published var validationPreviewImage: URL?

    public func update() {
        self.objectWillChange.send()
        if let views = self.outlierViews {
            for view in views { view.objectWillChange.send() }
        }
    }
    
    // this does a view layer only translation so that we don't have
    // to wait for the longer running background process to update the view
    public func userSelectAllOutliers(toShouldPaint shouldPaint: Bool,
                                      between startLocation: CGPoint,
                                      and endLocation: CGPoint) 
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

        let gestureBounds = BoundingBox(min: Coord(x: Int(minX), y: Int(minY)),
                                        max: Coord(x: Int(maxX), y: Int(maxY)))
        
        outlierViews?.forEach() { group in
            if gestureBounds.contains(other: group.bounds) {
                // check to make sure this outlier's bounding box is fully contained
                // otherwise don't change paint status

                group.group.shouldPaint = .userSelected(shouldPaint)
            }
            
        }
    }
}

fileprivate let initialImage = Image(systemName: "rectangle.fill").resizable()
fileprivate let initialAsyncImage = AsyncImage(url: nil)

