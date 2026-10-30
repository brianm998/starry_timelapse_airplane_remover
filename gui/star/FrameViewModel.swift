import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging
import StarCppBridge
import Combine

// UI view class used for each frame
@MainActor @Observable
public class FrameViewModel {

    var reloadID = UUID()

    let config: ConfigManager
    
    init(_ config: ConfigManager, _ frameIndex: Int) {
        self.config = config
        self.frameIndex = frameIndex
        let overrides = config.config().pixelReplacementOverrides
        if let overriddenValue = overrides[frameIndex] {
            self.defaultCleanMethod = overriddenValue
        } else {
            self.defaultCleanMethod = config.config().cleanMethod
        }
    }

    /// False while this frame's original has not been extracted from its video yet.
    var isExtracted = true

    var existingImages: Set<FrameViewMode> = [] {
        didSet { reportAvailabilityChange(from: oldValue, to: existingImages) }
    }

    /// Told when this frame gains image types (`added`) or loses some (`removed`), so the sequence
    /// can keep one running answer to "which image types does any frame have" instead of asking every
    /// frame each time a view draws. Set by `ImageSequenceViewModel`.
    @ObservationIgnored var onImageAvailabilityChange: ((_ added: Set<FrameViewMode>, _ removed: Bool) -> Void)?

    private func reportAvailabilityChange(from old: Set<FrameViewMode>, to new: Set<FrameViewMode>) {
        let added = new.subtracting(old)
        let removed = !old.subtracting(new).isEmpty
        if !added.isEmpty || removed { onImageAvailabilityChange?(added, removed) }
    }

    /// Every horizon line this frame has, one per kind, sized for its filmstrip thumbnail.
    /// Empty until `refreshHorizonOverlay()` completes, or when the frame has none.
    var horizonOverlays: [HorizonThumbnailOverlay] = []

    /// The same lines for the main frame edit view, in full frame pixel space
    /// (yPerColumn.count == frame.width).  Empty until `refreshFrameHorizonOverlay()` completes.
    var frameHorizonOverlays: [HorizonThumbnailOverlay] = []

    /// The same lines sized to the current grid cell dimensions.  The grid falls back to
    /// `horizonOverlays` until these are ready.  Empty until
    /// `refreshGridHorizonOverlay(width:height:)` completes.
    var gridHorizonOverlays: [HorizonThumbnailOverlay] = []

    /// Monotonically-increasing counter. Each call to refreshHorizonOverlay()
    /// stamps the launched task; only the most-recently-requested result is applied.
    private var horizonOverlayVersion: UInt = 0
    private var frameHorizonOverlayVersion: UInt = 0
    private var gridHorizonOverlayVersion: UInt = 0
    
    var frameObserver = FrameObserver()

    var frameState: FrameProcessingState?

    let defaultCleanMethod: CleanMethod

    var cleanMethod: CleanMethod {
        get {
            frameObserver.cleanMethod ?? defaultCleanMethod
        }
    }
    
    var outliersLoaded: OutlierLoadingState = .unloaded

    var outlierLoadIndex = 0 // used to indicate when we've reloaded outliers
    
    private var cancelBag = Set<AnyCancellable>()

    var isCurrentFrame: Bool = false

    var isPendingHorizonRefinement: Bool = false

    /// Aligned images this frame can build on demand: its homographies exist even though, in
    /// the default mode, the full-size aligned TIFFs are never written.
    var producibleImages: Set<FrameViewMode> = [] {
        didSet { reportAvailabilityChange(from: oldValue, to: producibleImages) }
    }

    func refreshProducibleImages() async {
        guard let frame else { return }
        var producible: Set<FrameViewMode> = []
        for type in [FrameViewMode.starAligned, .earthAligned] {
            if await frame.canProduceAlignedImage(of: type) { producible.insert(type) }
        }
        producibleImages = producible
    }

    func hasImage(type: FrameViewMode) -> Bool {
        if existingImages.contains(type) { return true }
        if producibleImages.contains(type) { return true }
        // userHorizon files (reference.tiff or per-frame) may be added after initial load
        // without updating existingImages for every frame, so do a lazy live check
        if type == .userHorizon,
           let exists = frame?.imageAccessor.imageExists(
             frameIndex: frameIndex, ofType: .userHorizon, atSize: .original
           )
        {
            if exists { existingImages.insert(.userHorizon) }
            return exists
        }
        return false
    }
    
    let frameIndex: Int

    func saved(
      image: PixelatedImage,
      ofType type: FrameViewMode,
      atSize size: ImageDisplaySize)
    {
        existingImages.insert(type)
        if size == .preview {
            reloadID = UUID()
        }
    }
    
    var frame: FrameAirplaneRemover? {
        didSet {
            //        Log.d("frame \(frameIndex) set frame to \(String(describing: frame))")

            cancelBag.removeAll()
            if let frame {
                for type in FrameViewMode.allCases {
                    if frame.imageAccessor.imageExists(
                         frameIndex: frame.frameIndex,
                         ofType: type,
                         atSize: .original
                       )
                    {
                        existingImages.insert(type)
                    }
                }
                Task { await self.refreshProducibleImages() }
                Task.detached {
                    await frame.set(observer: self.frameObserver)
                    try await frame.loadOutliers(loadOnly: true)
                    Task { @MainActor in
                        await self.setOutlierGroups()
                        self.refreshHorizonOverlay()
                        self.refreshFrameHorizonOverlay()
                    }
                }
            }
        }
    }

    // optional to distinguish between not loaded and empty list
    var outlierViews: [OutlierGroupViewModel]?
    var loadingOutlierViews: Bool = false

    var trashImage: Image?
    var loadingTrashViews: Bool = false

    // images for all outliers too small to have their own UI views
    var positiveOutlierImage: Image?
    var negativeOutlierImage: Image?
    
    @ViewBuilder
    public var thumbnailImage: some View {
        if let frame,
           let url = frame.imageAccessor.urlForImage(
             frameIndex: frame.frameIndex,
             ofType: .original,
             atSize: .thumbnail
           )
        {
            AsyncImage(
              url: url.appending(
                queryItems: [
                  URLQueryItem(
                    name: "v",
                    value: reloadID.uuidString
                  )
                ]
              )
            ) { image in
                image
            } placeholder: {
                initialImage
            }
        } else {
            ZStack {
                Color(white: 0.15)
                Text(localized("ui.n_a"))
                  .font(.largeTitle)
                  .foregroundColor(Color(white: 0.45))
            }
              .task(id: reloadID) {
                  if let frame = self.frame,
                     frame.imageAccessor.urlForImage(
                       frameIndex: frame.frameIndex,
                       ofType: .original,
                       atSize: .thumbnail
                     ) == nil
                  {
                      Task {
                          let op = PreviewOp(
                            frameView: self,
                            imageAccessor: frame.imageAccessor,
                            frameIndex: frame.frameIndex,
                            type: .original,
                            size: .thumbnail,
                            // A preview loads the full-resolution image to downscale it;
                            // without a unit the .preview multiplier gates nothing.
                            rawImageBytes: await frame.configManager.config().workingFrameBytes
                          ) { errorString in
                              Log.e("frame \(frame.frameIndex) unable to create thumbnail: \(errorString)")
                          }
                          op.queuePriority = .veryHigh
                          await frameGraphBuilder.add(operation: op)
                      }
                  }
              }
        }
    }

    @ViewBuilder
    public func previewImage(type: FrameViewMode) -> some View {
        if let frame,
           let url = frame.imageAccessor.urlForImage(
             frameIndex: frame.frameIndex,
             ofType: type,
             atSize: .preview
           )
        {
            AsyncImage(
              url: url.appending(
                queryItems: [
                  URLQueryItem(
                    name: "v",
                    value: reloadID.uuidString
                  )
                ]
              )
            ) { image in
                image.resizable()
            } placeholder: {
                initialImage
            }
        } else {
            ZStack {
                Color(white: 0.15)
                Text(localized("ui.image_not_found_for_frame", type.longName))
                  .font(.system(size: 28, weight: .medium))
                  .multilineTextAlignment(.center)
                  .padding()
                  .foregroundColor(Color(white: 0.45))
            }
              .task(id: reloadID) {
                  if let frame = self.frame,
                     frame.imageAccessor.urlForImage(
                       frameIndex: frame.frameIndex,
                       ofType: type,
                       atSize: .preview
                     ) == nil
                  {
                      Task {
                          let op = PreviewOp(
                            frameView: self,
                            imageAccessor: frame.imageAccessor,
                            frameIndex: frame.frameIndex,
                            type: type,
                            size: .preview,
                            rawImageBytes: await frame.configManager.config().workingFrameBytes
                          ) { errorString in
                              Log.e("frame \(frame.frameIndex) unable to create thumbnail: \(errorString)")
                          }
                          op.queuePriority = .veryHigh
                          await frameGraphBuilder.add(operation: op)
                      }
                  }
              }
        }
    }

    // puts view outliers into the trash
    public func dumpInTrash(between selectionStart: CGPoint,
                              and end_location: CGPoint)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        var newOutlierViews: [OutlierGroupViewModel] = []
        var trash: [OutlierGroup] = []

        outlierViews?.forEach() { group in
            if !gestureBounds.contains(other: group.bounds) {
                newOutlierViews.append(group)
            } else {
                trash.append(group.group)   
            }
        }
        self.outlierViews = newOutlierViews

        if let frame {
            Task.detached(priority: .userInitiated) {
                await frame.getOutlierGroups()?.dumpInTrash(trash)
                await self.computeSmallOutlierImage()
                await self.computeTrashImage()
                await frame.updateCombineSubjects()
                try await frame.getOutlierGroups()?.writeOutliersBinary(to: frame.outliersDirname)
            }
        }
    }

    // puts view outliers into the trash
    public func dumpInTrash(_ badGroup: OutlierGroup) {
        var newOutlierViews: [OutlierGroupViewModel] = []
        var trash: [OutlierGroup] = []

        outlierViews?.forEach() { group in
            if group.group.id == badGroup.id {
                trash.append(group.group)   
            } else {
                newOutlierViews.append(group)
            }
        }
        self.outlierViews = newOutlierViews

        if let frame {
            Task.detached(priority: .userInitiated) {
                await frame.getOutlierGroups()?.dumpInTrash(trash)
                await self.computeSmallOutlierImage()
                await self.computeTrashImage()
                try await frame.getOutlierGroups()?.writeOutliersBinary(to: frame.outliersDirname)
                await frame.updateCombineSubjects()
            }
        }
    }

    // pulls outliers out of the trash into the view
    public func extractDust(between selectionStart: CGPoint,
                            and end_location: CGPoint)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        if let frame {
            Task.detached(priority: .userInitiated) {
                let _ = try await frame.promoteDust(in: gestureBounds)

                await self.computeSmallOutlierImage()
                // update the trash image
                await self.computeTrashImage()
                
                await self.setOutlierGroups()
                await frame.updateCombineSubjects()            
            }
        }
    }


    func computeSmallOutlierImage() {
        guard let frame else {
            Log.w("cannot compute small outlier image with no frame reference")
            return
        }
        /*
         _Much_ better UI performance when outliers smaller than a threshold of
         around 40 pixels are not presented in the UI separate from these images

         compute here two images which are similar to the trash image,
         but instead contain all outliers smaller than a given threshold.
         One image for outliers we will paint, the other for outliers we will not.
         each is a monochrome image, can be displayed in the view layer as colored.

         XXX

         still need to:

         - make the hardcoded '40' value here in in FrameEditView a runtime UI config

         */
        
        let width  = Int(frame.width)
        let height = Int(frame.height)
        Task.detached(priority: .userInitiated) {
            var positiveOutlierArray = [UInt8](repeating: 0, count: 2*width*height)
            var negativeOutlierArray = [UInt8](repeating: 0, count: 2*width*height)
            if let outlierGroups = await frame.getOutlierGroups() {
                for group in await outlierGroups.getMembers().values {
                    if group.size <= 40 { // XXX sync with same value @ FrameEditView:139
                        if let shouldRemove = await group.shouldRemove(),
                           shouldRemove.willRemove
                      {
                            for pixel in group.pixelSet {
                                let index = 2*(pixel.y*width+pixel.x)
                                var value = pixel.uInt16Value/0xFF
                                if value > UInt8.max { value = UInt16(UInt8.max) }
                                positiveOutlierArray[index] = UInt8(value)
                                positiveOutlierArray[index+1] = 0xFF // make it visible
                            }
                        } else {
                            for pixel in group.pixelSet {
                                let index = 2*(pixel.y*width+pixel.x)
                                var value = pixel.uInt16Value/0xFF
                                if value > UInt8.max { value = UInt16(UInt8.max) }
                                negativeOutlierArray[index] = UInt8(value)
                                negativeOutlierArray[index+1] = 0xFF // make it visible
                            }
                        }
                    }
                }
            }

            if let dataProvider = CGDataProvider(data: positiveOutlierArray.data as CFData),
               let image = CGImage(width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bitsPerPixel: 16,
                                   bytesPerRow: 2*width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: false,
                                   intent: .defaultIntent)
            {
                let nsImage = NSImage(cgImage: image, size: .zero)
                let swiftUIImage = Image(nsImage: nsImage)
                await MainActor.run {
                    self.positiveOutlierImage = swiftUIImage
                }
            }

            if let dataProvider = CGDataProvider(data: negativeOutlierArray.data as CFData),
               let image = CGImage(width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bitsPerPixel: 16,
                                   bytesPerRow: 2*width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: false,
                                   intent: .defaultIntent)
            {
                let nsImage = NSImage(cgImage: image, size: .zero)
                let swiftUIImage = Image(nsImage: nsImage)
                await MainActor.run {
                    self.negativeOutlierImage = swiftUIImage
                }
            }
        }
    }
    
    func computeTrashImage() {
        guard let frame else {
            Log.w("cannot compute trash image with no frame reference")
            return
        }
        // write an image from all of the trash, as there can be too much trash
        // to make each particle an outlier view 
        let width  = Int(frame.width)
        let height = Int(frame.height)
        Log.d("computing trash image for frame \(frame.frameIndex)")
        Task.detached(priority: .userInitiated) {
            var trashArray = [UInt8](repeating: 0, count: 2*width*height)
            if let outlierGroups = await frame.outlierGroupTrashList() {
                Log.d("frame \(frame.frameIndex) has \(outlierGroups.count) trash groups")
                for group in outlierGroups {
                    for pixel in group.pixelSet {
                        let index = 2*(pixel.y*width+pixel.x)
                        var value = pixel.uInt16Value/0xFF
                        if value > UInt8.max { value = UInt16(UInt8.max) }
                        if index < trashArray.count {
                            trashArray[index] = UInt8(value)
                            trashArray[index+1] = 0xFF // make it visible
                        } else {
                            Log.w("pixel \(pixel) has invalid index")
                        }
                    }
                }
            } else {
                Log.d("frame \(frame.frameIndex) has NO outliers :(")
            }

            Log.d("computed trash image for frame \(frame.frameIndex)")
            if let dataProvider = CGDataProvider(data: trashArray.data as CFData),
               let image = CGImage(width: width,
                                   height: height,
                                   bitsPerComponent: 8,
                                   bitsPerPixel: 16,
                                   bytesPerRow: 2*width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: false,
                                   intent: .defaultIntent)
            {
                let nsImage = NSImage(cgImage: image, size: .zero)
                let swiftUIImage = Image(nsImage: nsImage)
                await MainActor.run {
                    Log.d("set trash image for frame \(frame.frameIndex)")
                    self.trashImage = swiftUIImage
                }
            }
        }
    }
    
    func refreshHorizonOverlay() {
        guard let frame else {
            horizonOverlays = []
            return
        }
        let tw = config.config().thumbnailWidth
        let th = config.config().thumbnailHeight
        horizonOverlayVersion &+= 1
        let version = horizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlays = await frame.loadHorizonThumbnailOverlays(
                thumbnailWidth:  tw,
                thumbnailHeight: th
            )
            await MainActor.run {
                guard self.horizonOverlayVersion == version else { return }
                self.horizonOverlays = overlays
                self.reloadID = UUID()
            }
        }
    }

    /// This frame's horizon lines changed on disk (`ImageAccessor.horizonChangedClosure`): draw
    /// them again, wherever they are drawn.  A burst — a mask written at two sizes, a consensus
    /// line and its image — is one reload, a quarter of a second after it starts; each reload
    /// decodes the frame's masks, so a frame-size or grid set nothing has asked for stays unmade.
    func horizonLinesChanged() {
        guard !horizonReloadScheduled else { return }
        horizonReloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            horizonReloadScheduled = false
            refreshHorizonOverlay()
            if isCurrentFrame || !frameHorizonOverlays.isEmpty { refreshFrameHorizonOverlay() }
            if let gridOverlaySize {
                refreshGridHorizonOverlay(width: gridOverlaySize.width, height: gridOverlaySize.height)
            }
        }
    }

    private var horizonReloadScheduled = false

    /// The size `gridHorizonOverlays` was last made at, to remake them at when the lines change.
    private var gridOverlaySize: (width: Int, height: Int)? = nil

    func refreshFrameHorizonOverlay() {
        guard let frame else {
            frameHorizonOverlays = []
            return
        }
        let fw = frame.width
        let fh = frame.height
        frameHorizonOverlayVersion &+= 1
        let version = frameHorizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlays = await frame.loadHorizonThumbnailOverlays(
                thumbnailWidth:  fw,
                thumbnailHeight: fh
            )
            await MainActor.run {
                guard self.frameHorizonOverlayVersion == version else { return }
                self.frameHorizonOverlays = overlays
            }
        }
    }

    /// Regenerate the horizon overlay at the given pixel dimensions for accurate
    /// grid-cell display. Does NOT bump reloadID so the preview image is not re-fetched.
    func refreshGridHorizonOverlay(width: Int, height: Int) {
        gridOverlaySize = (width, height)
        guard let frame else {
            gridHorizonOverlays = []
            return
        }
        gridHorizonOverlayVersion &+= 1
        let version = gridHorizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlays = await frame.loadHorizonThumbnailOverlays(
                thumbnailWidth:  width,
                thumbnailHeight: height
            )
            await MainActor.run {
                guard self.gridHorizonOverlayVersion == version else { return }
                self.gridHorizonOverlays = overlays
            }
        }
    }

    func setOutlierGroups(forced: Bool = false) async {
        guard let frame else {
            Log.w("cannot set outlier groups with no frame reference")
            return
        }
        Task.detached(priority: .userInitiated) {
            let outlierGroups = await frame.outlierGroupList()
            if let outlierGroups {
                Log.d("got \(outlierGroups.count) groups for frame \(frame.frameIndex)")
                var newOutlierGroups: [OutlierGroupViewModel] = []
                for group in outlierGroups {
                    if let cgImage = await group.testImage() { // XXX heap corruption here :(
                        var size = CGSize()
                        size.width = CGFloat(cgImage.width)
                        size.height = CGFloat(cgImage.height)
                        let outlierImage = NSImage(cgImage: cgImage, size: size)
                        
                        let groupView = await OutlierGroupViewModel(viewModel: self,
                                                                    group: group,
                                                                    name: group.id,
                                                                    bounds: group.bounds,
                                                                    image: outlierImage)
                        newOutlierGroups.append(groupView)
                    } else {
                        Log.e("frame \(frame.frameIndex) outlier group no image")
                    }
                }
                
                let foo = newOutlierGroups
                await MainActor.run {
                    self.outlierViews = foo
                    if !forced { self.outlierLoadIndex += 1 }
                }
            } else {
                // need to load outliers, we don't have any
            }
        }
    }
    
}

// XXX make this a loading view
fileprivate let initialImage = Image(systemName: "rectangle.fill").resizable()


