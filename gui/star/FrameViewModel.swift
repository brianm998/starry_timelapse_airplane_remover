import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging
import KHTSwift
import Combine

// UI view class used for each frame
@Observable
public class FrameViewModel {
    init(_ frameIndex: Int) {
        self.frameIndex = frameIndex
    }

    private var cancelBag = Set<AnyCancellable>()

    var isCurrentFrame: Bool = false
    
    let frameIndex: Int
    var frame: FrameAirplaneRemover? {
        didSet {
            Log.d("frame \(frameIndex) set frame to \(String(describing: frame))")
            cancelBag.removeAll()
            if let frame {
                Task {
                    // XXX run on main actor?
                    await frame.numberOfPositiveOutliersPublisher()
                      .sink { [weak self] value in
                          print("EAT ME \(value) positive")
                          self?.numberOfPositiveOutliers = value
                      } 
                      .store(in: &cancelBag)

                    await frame.numberOfNegativeOutliersPublisher()
                      .sink { [weak self] value in
                          self?.numberOfNegativeOutliers = value
                      } 
                      .store(in: &cancelBag)

                    await frame.numberOfUnknownOutliersPublisher()
                      .sink { [weak self] value in
                          self?.numberOfUndecidedOutliers = value
                      } 
                      .store(in: &cancelBag)
                }
            }
        }
    }

    // XXX turn these into properties that are updated when the paintability changes
    // have the FrameAirplaneRemover be able to both knows these values,
    // and transmit changes to the UI with a callback that updates view state

    var numberOfPositiveOutliers: Int? 
    var numberOfNegativeOutliers: Int? 
    var numberOfUndecidedOutliers: Int?
    
    // optional to distinguish between not loaded and empty list
    var outlierViews: [OutlierGroupViewModel]?
    var loadingOutlierViews: Bool = false

    // we don't keep full resolution images here

    var thumbnailImage: Image = initialImage
    var previewImage: Image = initialImage
    var processedPreviewImage: Image = initialImage
    var subtractionPreviewImage: Image = initialImage
    var blobsPreviewImage: Image = initialImage
    var khtbPreviewImage: Image = initialImage
    var filter1PreviewImage: Image = initialImage
    var filter2PreviewImage: Image = initialImage
    var filter3PreviewImage: Image = initialImage
    var filter4PreviewImage: Image = initialImage
    var filter5PreviewImage: Image = initialImage
    var filter6PreviewImage: Image = initialImage
    var paintMaskPreviewImage: Image = initialImage
    var houghLinesPreviewImage: Image = initialImage
    var validationPreviewImage: Image = initialImage

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
    
    public func deleteOutliers(between selectionStart: CGPoint,
                               and end_location: CGPoint) -> BoundingBox
    {
        let gestureBounds = boundsFromGesture(between: selectionStart, and: end_location)

        Log.d("deleteOutliers with gestureBounds \(gestureBounds)")
        
        var newOutlierViews: [OutlierGroupViewModel] = []

        // XXX bug here where no outliers get appended,
        // and they all dissapear from the view :(
        
        outlierViews?.forEach() { group in
            if !gestureBounds.contains(other: group.bounds) {
                newOutlierViews.append(group)
            }
        }
        self.outlierViews = newOutlierViews

        return gestureBounds
    }
}

// XXX make this a loading view
fileprivate let initialImage = Image(systemName: "clock.circle.fill").resizable()
