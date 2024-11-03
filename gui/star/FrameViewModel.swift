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

    func alignedPreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.aligned,
                        cachedOnly: cachedOnly,
                        storage: &_alignedPreviewImage) { image in
            self._alignedPreviewImage = image
        }
    }

    private var _subtractionPreviewImage: Image?

    private func subtractionPreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.subtraction,
                        cachedOnly: cachedOnly,
                        storage: &_subtractionPreviewImage) { image in
            self._subtractionPreviewImage = image
        }
    }

    private var _blobsPreviewImage: Image?

    private func blobsPreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.blobs,
                        cachedOnly: cachedOnly,
                        storage: &_blobsPreviewImage) { image in
            self._blobsPreviewImage = image
        }
    }

    private var _filter1PreviewImage: Image?

    private func filter1PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter1,
                        cachedOnly: cachedOnly,
                        storage: &_filter1PreviewImage) { image in
            self._filter1PreviewImage = image
        }
    }

    private var _filter2PreviewImage: Image?

    private func filter2PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter2,
                        cachedOnly: cachedOnly,
                        storage: &_filter2PreviewImage) { image in
            self._filter2PreviewImage = image
        }
    }

    private var _filter3PreviewImage: Image?

    private func filter3PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter3,
                        cachedOnly: cachedOnly,
                        storage: &_filter3PreviewImage) { image in
            self._filter3PreviewImage = image
        }
    }

    private var _filter4PreviewImage: Image?

    private func filter4PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter4,
                        cachedOnly: cachedOnly,
                        storage: &_filter4PreviewImage) { image in
            self._filter4PreviewImage = image
        }
    }

    private var _filter5PreviewImage: Image?

    private func filter5PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter5,
                        cachedOnly: cachedOnly,
                        storage: &_filter5PreviewImage) { image in
            self._filter5PreviewImage = image
        }
    }

    private var _filter6PreviewImage: Image?

    private func filter6PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter6,
                        cachedOnly: cachedOnly,
                        storage: &_filter6PreviewImage) { image in
            self._filter6PreviewImage = image
        }
    }

    private var _filter7PreviewImage: Image?

    private func filter7PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter7,
                        cachedOnly: cachedOnly,
                        storage: &_filter7PreviewImage) { image in
            self._filter7PreviewImage = image
        }
    }
    
    private var _filter8PreviewImage: Image?

    private func filter8PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter8,
                        cachedOnly: cachedOnly,
                        storage: &_filter8PreviewImage) { image in
            self._filter8PreviewImage = image
        }
    }

    private var _filter9PreviewImage: Image?

    private func filter9PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter9,
                        cachedOnly: cachedOnly,
                        storage: &_filter9PreviewImage) { image in
            self._filter9PreviewImage = image
        }
    }

    private var _filter10PreviewImage: Image?

    private func filter10PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter10,
                        cachedOnly: cachedOnly,
                        storage: &_filter10PreviewImage) { image in
            self._filter10PreviewImage = image
        }
    }
    
    private var _filter11PreviewImage: Image?

    private func filter11PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter11,
                        cachedOnly: cachedOnly,
                        storage: &_filter11PreviewImage) { image in
            self._filter11PreviewImage = image
        }
    }

    private var _filter12PreviewImage: Image?

    private func filter12PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter12,
                        cachedOnly: cachedOnly,
                        storage: &_filter12PreviewImage) { image in
            self._filter12PreviewImage = image
        }
    }

    private var _filter13PreviewImage: Image?

    private func filter13PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter13,
                        cachedOnly: cachedOnly,
                        storage: &_filter13PreviewImage) { image in
            self._filter13PreviewImage = image
        }
    }
    
    private var _filter14PreviewImage: Image?

    private func filter14PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter14,
                        cachedOnly: cachedOnly,
                        storage: &_filter14PreviewImage) { image in
            self._filter14PreviewImage = image
        }
    }

    private var _filter15PreviewImage: Image?

    private func filter15PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter15,
                        cachedOnly: cachedOnly,
                        storage: &_filter15PreviewImage) { image in
            self._filter15PreviewImage = image
        }
    }

    private var _filter16PreviewImage: Image?

    private func filter16PreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.filter16,
                        cachedOnly: cachedOnly,
                        storage: &_filter16PreviewImage) { image in
            self._filter16PreviewImage = image
        }
    }

    private var _paintMaskPreviewImage: Image?

    private func paintMaskPreviewImage(cachedOnly: Bool = false) -> Image {
        return lazyLoad(.paintMask,
                        cachedOnly: cachedOnly,
                        storage: &_paintMaskPreviewImage) { image in
            self._paintMaskPreviewImage = image
        }
    }
    
    private var _validationPreviewImage: Image?

    private func validationPreviewImage(cachedOnly: Bool = false) -> Image { 
        return lazyLoad(.validation,
                        cachedOnly: cachedOnly,
                        storage: &_validationPreviewImage) { image in
            self._validationPreviewImage = image
        }
    }
    
    private func lazyLoad(_ type: FrameViewMode,
                          cachedOnly: Bool,
                          storage: inout Image?,
                          closure: @escaping (Image) -> Void) -> Image
    {
        if let storage { return storage }
        if cachedOnly { return initialImage }
        if let frame {
            Task {
                let bgTask = Task.detached {
                    frame.imageAccessor.loadImage(type: type,
                                                  atSize: .preview)?.resizable()
                }
                if let image = await bgTask.value {
//                    print("FUCKING image")
                    closure(image)
                } else {
//                    print("FUCKING FUCK")
                    closure(initialImage)
                }
            }
        }

        if viewModel.frameViewMode != viewModel.previousFrameViewMode {
            // show previous image while loading if we can

            // XXX show loading icon on top
//            print("FUCKING viewModel.previousFrameViewMode \(viewModel.previousFrameViewMode)")
            return previewImage(type: viewModel.previousFrameViewMode, cachedOnly: true)
        } else {
            return initialImage
        }
    }
    
    public func previewImage(type: FrameViewMode, cachedOnly: Bool = false) -> Image {
        switch type {
        case .original:
            return self.previewImage
        case .processed:
            return self.processedPreviewImage
        case .subtraction:
            return self.subtractionPreviewImage(cachedOnly: cachedOnly)
        case .blobs:
            return self.blobsPreviewImage(cachedOnly: cachedOnly)
        case .filter1:
            return self.filter1PreviewImage(cachedOnly: cachedOnly)
        case .filter2:
            return self.filter2PreviewImage(cachedOnly: cachedOnly)
        case .filter3:
            return self.filter3PreviewImage(cachedOnly: cachedOnly)
        case .filter4:
            return self.filter4PreviewImage(cachedOnly: cachedOnly)
        case .filter5:
            return self.filter5PreviewImage(cachedOnly: cachedOnly)
        case .filter6:
            return self.filter6PreviewImage(cachedOnly: cachedOnly)
        case .filter7:
            return self.filter7PreviewImage(cachedOnly: cachedOnly)
        case .filter8:
            return self.filter8PreviewImage(cachedOnly: cachedOnly)
        case .filter9:
            return self.filter9PreviewImage(cachedOnly: cachedOnly)
        case .filter10:
            return self.filter10PreviewImage(cachedOnly: cachedOnly)
        case .filter11:
            return self.filter11PreviewImage(cachedOnly: cachedOnly)
        case .filter12:
            return self.filter12PreviewImage(cachedOnly: cachedOnly)
        case .filter13:
            return self.filter13PreviewImage(cachedOnly: cachedOnly)
        case .filter14:
            return self.filter14PreviewImage(cachedOnly: cachedOnly)
        case .filter15:
            return self.filter15PreviewImage(cachedOnly: cachedOnly)
        case .filter16:
            return self.filter16PreviewImage(cachedOnly: cachedOnly)
        case .paintMask:
            return self.paintMaskPreviewImage(cachedOnly: cachedOnly)
        case .validation:
            return self.validationPreviewImage(cachedOnly: cachedOnly)
        case .aligned:
            return self.alignedPreviewImage(cachedOnly: cachedOnly)
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


