import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging
import KHTSwift
import Combine

// UI view class used for each frame
@MainActor @Observable
public class FrameViewModel {

    init(_ frameIndex: Int, viewModel: ImageSequenceViewModel) {
        self.frameIndex = frameIndex
        self.viewModel = viewModel
    }

    let viewModel: ImageSequenceViewModel

    var existingImages: Set<FrameViewMode> = []
    
    var frameObserver = FrameObserver()

    var frameState: FrameProcessingState?

    var outliersLoaded: OutlierLoadingState = .unloaded
    
    private var cancelBag = Set<AnyCancellable>()

    var isCurrentFrame: Bool = false

    func hasImage(type: FrameViewMode) -> Bool { existingImages.contains(type) }
    
    let frameIndex: Int

    func savedImage(_ image: PixelatedImage, ofType type: FrameViewMode, atSize size: ImageDisplaySize) {
        existingImages.insert(type)
        if size == .preview {
            switch type {
            case .processed:
                if let image = image.nsImage {
                    self.processedPreviewImage = Image(nsImage: image)
                      .resizable()
                }
            case .original:
                if let image = image.nsImage {
                    self.previewImage = Image(nsImage: image)
                      .resizable()
                }
            default:
                 break
            }
        }
    }
    
    var frame: FrameAirplaneRemover? {
        didSet {
            //        Log.d("frame \(frameIndex) set frame to \(String(describing: frame))")

            cancelBag.removeAll()
            if let frame {
                Task {
                    await frame.set(observer: frameObserver)
                }
            }
        }
    }

    // XXX turn these into properties that are updated when the paintability changes
    // have the FrameAirplaneRemover be able to both knows these values,
    // and transmit changes to the UI with a callback that updates view state

//    var numberOfPositiveOutliers: Int? 
//    var numberOfNegativeOutliers: Int? 
//    var numberOfUndecidedOutliers: Int?
    
    // optional to distinguish between not loaded and empty list
    var outlierViews: [OutlierGroupViewModel]?
    var loadingOutlierViews: Bool = false

    // we don't keep full resolution images here

    var thumbnailImage: Image = initialImage
    var previewImage: Image = initialImage
    var processedPreviewImage: Image = initialImage
 
    public func previewImage(type: FrameViewMode) -> some View {
        Group {
            switch type {
            case .original:
                self.previewImage
            case .processed:
                self.processedPreviewImage
            default: 
                if let frame {
                    /*
                    if frame.imageAccessor.imageExists(ofType: type, atSize: .original),
                       !frame.imageAccessor.imageExists(ofType: .aligned, atSize: .preview)
                    {
                        Task.detached {
                            try? await frame.imageAccessor.writeMissingImage(ofType: .aligned, andSize: .preview)
                        }
                    }*/

                    
                    AsyncImage(url: frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: type, atSize: .preview)) { image in
                        image.resizable()
                    } placeholder: {
                        initialImage
                    }
                } else {

                    
                    initialImage
                }
            }
        }
    }

    public func deleteOutliers(between selectionStart: CGPoint,
                               and end_location: CGPoint) -> BoundingBox
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

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
fileprivate let initialImage = Image(systemName: "rectangle.fill").resizable()


