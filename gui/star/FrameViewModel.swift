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

    // optional to distinguish between not loaded and empty list
    var outlierViews: [OutlierGroupViewModel]?
    var loadingOutlierViews: Bool = false

    var shouldShowDustbin = false
    var dustbinImage: Image?
    var loadingDustbinViews: Bool = false

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

    // puts view outliers into the dustbin
    public func dumpInDustbin(between selectionStart: CGPoint,
                              and end_location: CGPoint)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        var newOutlierViews: [OutlierGroupViewModel] = []
        var dustbin: [OutlierGroup] = []

        outlierViews?.forEach() { group in
            if !gestureBounds.contains(other: group.bounds) {
                newOutlierViews.append(group)
            } else {
                dustbin.append(group.group)   
            }
        }
        self.outlierViews = newOutlierViews

        if let frame {
            Task {
                await frame.getOutlierGroups()?.dumpInDustbin(dustbin)
                await self.viewModel.computeDustbinImage(forFrame: frame)
                await frame.updateCombineSubjects()
                try await frame.getOutlierGroups()?.writeOutliersBinary(to: frame.outliersDirname)
            }
        }
    }

    // puts view outliers into the dustbin
    public func dumpInDustbin(_ badGroup: OutlierGroup) {
        var newOutlierViews: [OutlierGroupViewModel] = []
        var dustbin: [OutlierGroup] = []

        outlierViews?.forEach() { group in
            if group.group.id == badGroup.id {
                dustbin.append(group.group)   
            } else {
                newOutlierViews.append(group)
            }
        }
        self.outlierViews = newOutlierViews

        if let frame {
            Task {
                await frame.getOutlierGroups()?.dumpInDustbin(dustbin)
                await self.viewModel.computeDustbinImage(forFrame: frame)
                try await frame.getOutlierGroups()?.writeOutliersBinary(to: frame.outliersDirname)
                await frame.updateCombineSubjects()
            }
        }
    }

    // pulls outliers out of the dustbin into the view
    public func extractDust(between selectionStart: CGPoint,
                            and end_location: CGPoint)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        Task {
            if let frame {
                let newViewOutliers = try await frame.promoteDust(in: gestureBounds)

                await viewModel.setOutlierGroups(forFrame: frame)
                await frame.updateCombineSubjects()            
            }
        }
    }
}

// XXX make this a loading view
fileprivate let initialImage = Image(systemName: "rectangle.fill").resizable()


