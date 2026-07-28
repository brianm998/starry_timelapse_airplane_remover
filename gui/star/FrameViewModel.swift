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

    var existingImages: Set<FrameViewMode> = []

    /// The best-available horizon overlay for this frame's filmstrip thumbnail.
    /// Nil until `refreshHorizonOverlay()` completes.
    var horizonOverlay: HorizonThumbnailOverlay? = nil

    /// Full-resolution horizon overlay for display on the main frame edit view.
    /// Coordinates are in full frame pixel space (yPerColumn.count == frame.width).
    /// Nil until `refreshFrameHorizonOverlay()` completes.
    var frameHorizonOverlay: HorizonThumbnailOverlay? = nil

    /// Horizon overlay sized to the current grid cell dimensions.
    /// Falls back to `horizonOverlay` in the grid view until this is ready.
    /// Nil until `refreshGridHorizonOverlay(width:height:)` completes.
    var gridHorizonOverlay: HorizonThumbnailOverlay? = nil

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

    func hasImage(type: FrameViewMode) -> Bool {
        if existingImages.contains(type) { return true }
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
                Text("N/A")
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
                Text("\(type.longName) image not found for this frame")
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
            horizonOverlay = nil
            return
        }
        let tw = config.config().thumbnailWidth
        let th = config.config().thumbnailHeight
        horizonOverlayVersion &+= 1
        let version = horizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlay = try? await frame.loadHorizonThumbnailOverlay(
                thumbnailWidth:  tw,
                thumbnailHeight: th
            )
            await MainActor.run {
                guard self.horizonOverlayVersion == version else { return }
                self.horizonOverlay = overlay
                self.reloadID = UUID()
            }
        }
    }

    func refreshFrameHorizonOverlay() {
        guard let frame else {
            frameHorizonOverlay = nil
            return
        }
        let fw = frame.width
        let fh = frame.height
        frameHorizonOverlayVersion &+= 1
        let version = frameHorizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlay = try? await frame.loadHorizonThumbnailOverlay(
                thumbnailWidth:  fw,
                thumbnailHeight: fh
            )
            await MainActor.run {
                guard self.frameHorizonOverlayVersion == version else { return }
                self.frameHorizonOverlay = overlay
            }
        }
    }

    /// Regenerate the horizon overlay at the given pixel dimensions for accurate
    /// grid-cell display. Does NOT bump reloadID so the preview image is not re-fetched.
    func refreshGridHorizonOverlay(width: Int, height: Int) {
        guard let frame else {
            gridHorizonOverlay = nil
            return
        }
        gridHorizonOverlayVersion &+= 1
        let version = gridHorizonOverlayVersion
        Task.detached(priority: .utility) {
            let overlay = try? await frame.loadHorizonThumbnailOverlay(
                thumbnailWidth:  width,
                thumbnailHeight: height
            )
            await MainActor.run {
                guard self.gridHorizonOverlayVersion == version else { return }
                self.gridHorizonOverlay = overlay
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


