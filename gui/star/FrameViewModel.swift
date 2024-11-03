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

    init(_ frameIndex: Int, viewModel: ViewModel) {
        self.frameIndex = frameIndex
        self.viewModel = viewModel
    }

    let viewModel: ViewModel
    
    var frameObserver = FrameObserver()

    private var cancelBag = Set<AnyCancellable>()

    var isCurrentFrame: Bool = false

    let frameIndex: Int
    var frame: FrameAirplaneRemover? {
        didSet {
            Log.d("frame \(frameIndex) set frame to \(String(describing: frame))")

            cancelBag.removeAll()
            if let frame {
                Task {
                    await frame.set(observer: frameObserver)
                    /*

                     

                     XXX not hooked up to the UI or from the frame either yet :(




                     VVV these go away
                     
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
 */
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

    // should load all of these lazy

    private var _alignedPreviewImage: Image?

    var alignedPreviewImage: Image {
        return lazyLoad(.aligned, storage: &_alignedPreviewImage) { image in
            self._alignedPreviewImage = image
        }
    }

    private var _subtractionPreviewImage: Image?

    var subtractionPreviewImage: Image {
        return lazyLoad(.subtraction, storage: &_subtractionPreviewImage) { image in
            self._subtractionPreviewImage = image
        }
    }

    private var _blobsPreviewImage: Image?

    var blobsPreviewImage: Image {
        return lazyLoad(.blobs, storage: &_blobsPreviewImage) { image in
            self._blobsPreviewImage = image
        }
    }

    private var _filter1PreviewImage: Image?

    var filter1PreviewImage: Image {
        return lazyLoad(.filter1, storage: &_filter1PreviewImage) { image in
            self._filter1PreviewImage = image
        }
    }

    private var _filter2PreviewImage: Image?

    var filter2PreviewImage: Image {
        return lazyLoad(.filter2, storage: &_filter2PreviewImage) { image in
            self._filter2PreviewImage = image
        }
    }

    private var _filter3PreviewImage: Image?

    var filter3PreviewImage: Image {
        return lazyLoad(.filter3, storage: &_filter3PreviewImage) { image in
            self._filter3PreviewImage = image
        }
    }

    private var _filter4PreviewImage: Image?

    var filter4PreviewImage: Image {
        return lazyLoad(.filter4, storage: &_filter4PreviewImage) { image in
            self._filter4PreviewImage = image
        }
    }

    private var _filter5PreviewImage: Image?

    var filter5PreviewImage: Image {
        return lazyLoad(.filter5, storage: &_filter5PreviewImage) { image in
            self._filter5PreviewImage = image
        }
    }

    private var _filter6PreviewImage: Image?

    var filter6PreviewImage: Image {
        return lazyLoad(.filter6, storage: &_filter6PreviewImage) { image in
            self._filter6PreviewImage = image
        }
    }

    private var _filter7PreviewImage: Image?

    var filter7PreviewImage: Image {
        return lazyLoad(.filter7, storage: &_filter7PreviewImage) { image in
            self._filter7PreviewImage = image
        }
    }
    
    private var _filter8PreviewImage: Image?

    var filter8PreviewImage: Image {
        return lazyLoad(.filter8, storage: &_filter8PreviewImage) { image in
            self._filter8PreviewImage = image
        }
    }

    private var _filter9PreviewImage: Image?

    var filter9PreviewImage: Image {
        return lazyLoad(.filter9, storage: &_filter9PreviewImage) { image in
            self._filter9PreviewImage = image
        }
    }

    private var _filter10PreviewImage: Image?

    var filter10PreviewImage: Image {
        return lazyLoad(.filter10, storage: &_filter10PreviewImage) { image in
            self._filter10PreviewImage = image
        }
    }
    
    private var _filter11PreviewImage: Image?

    var filter11PreviewImage: Image {
        return lazyLoad(.filter11, storage: &_filter11PreviewImage) { image in
            self._filter11PreviewImage = image
        }
    }

    private var _filter12PreviewImage: Image?

    var filter12PreviewImage: Image {
        return lazyLoad(.filter12, storage: &_filter12PreviewImage) { image in
            self._filter12PreviewImage = image
        }
    }

    private var _filter13PreviewImage: Image?

    var filter13PreviewImage: Image {
        return lazyLoad(.filter13, storage: &_filter13PreviewImage) { image in
            self._filter13PreviewImage = image
        }
    }
    
    private var _filter14PreviewImage: Image?

    var filter14PreviewImage: Image {
        return lazyLoad(.filter14, storage: &_filter14PreviewImage) { image in
            self._filter14PreviewImage = image
        }
    }

    private var _filter15PreviewImage: Image?

    var filter15PreviewImage: Image {
        return lazyLoad(.filter15, storage: &_filter15PreviewImage) { image in
            self._filter15PreviewImage = image
        }
    }

    private var _filter16PreviewImage: Image?

    var filter16PreviewImage: Image {
        return lazyLoad(.filter16, storage: &_filter16PreviewImage) { image in
            self._filter16PreviewImage = image
        }
    }

    private var _paintMaskPreviewImage: Image?

    var paintMaskPreviewImage: Image {
        return lazyLoad(.paintMask, storage: &_paintMaskPreviewImage) { image in
            self._paintMaskPreviewImage = image
        }
    }
    
    private var _validationPreviewImage: Image?

    var validationPreviewImage: Image {
        return lazyLoad(.validation, storage: &_validationPreviewImage) { image in
            self._validationPreviewImage = image
        }
    }
    
    private func lazyLoad(_ type: FrameViewMode,
                          storage: inout Image?,
                          closure: @escaping (Image) -> Void) -> Image
    {
        if let storage { return storage }

        if let frame {
            Task {
                let bgTask = Task.detached {
                    frame.imageAccessor.loadImage(type: type,
                                                  atSize: .preview)?.resizable()
                }
                if let image = await bgTask.value {
                    closure(image)
                }
            }
        }

        if viewModel.frameViewMode != viewModel.previousFrameViewMode {
            return previewImage(type: viewModel.previousFrameViewMode)
        } else {
            return initialImage
        }
    }
    
    public func previewImage(type: FrameViewMode) -> Image {
        switch type {
        case .original:
            return self.previewImage
        case .subtraction:
            return self.subtractionPreviewImage
        case .blobs:
            return self.blobsPreviewImage
        case .filter1:
            return self.filter1PreviewImage
        case .filter2:
            return self.filter2PreviewImage
        case .filter3:
            return self.filter3PreviewImage
        case .filter4:
            return self.filter4PreviewImage
        case .filter5:
            return self.filter5PreviewImage
        case .filter6:
            return self.filter6PreviewImage
        case .filter7:
            return self.filter7PreviewImage
        case .filter8:
            return self.filter8PreviewImage
        case .filter9:
            return self.filter9PreviewImage
        case .filter10:
            return self.filter10PreviewImage
        case .filter11:
            return self.filter11PreviewImage
        case .filter12:
            return self.filter12PreviewImage
        case .filter13:
            return self.filter13PreviewImage
        case .filter14:
            return self.filter14PreviewImage
        case .filter15:
            return self.filter15PreviewImage
        case .filter16:
            return self.filter16PreviewImage
        case .paintMask:
            return self.paintMaskPreviewImage
        case .validation:
            return self.validationPreviewImage
        case .processed:
            return self.processedPreviewImage
        case .aligned:
            return self.alignedPreviewImage
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
//fileprivate let initialImage = Rectangle().fill(.black)


