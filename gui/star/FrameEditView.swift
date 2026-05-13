import SwiftUI
import StarCore
import logging

// the view for when the user wants to edit what outlier groups are painted and not

actor ArrayActor<T> {
    private var elements: [T] = []
    
    public func getElements() -> [T] { elements }
    public func append(_ element: T) { elements.append(element) }
}

struct FrameEditView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(ViewModel.self) var topViewModel: ViewModel
    @Environment(\.openWindow) private var openWindow

    // this one is optional, but it's passed as non-optional below
    @State private var currentZoomScale: CGFloat? = nil

    /// Owned here so both `HorizonPainterView` (canvas, scaled) and
    /// `HorizonPainterToolbarView` (toolbar, screen-sized) share the same state.
    @State private var horizonPaintState: HorizonPaintState? = nil

    var body: some View {
        // wrap the frame view with a zoomable view
        GeometryReader { geometry in
            // this is to account for the outlier arrows on the sides of the frame
            let outlierArrowLength = self.viewModel.frameWidth/self.viewModel.outlierArrowLength
            
            let min = (geometry.size.height/(viewModel.frameHeight+outlierArrowLength*2))
            let full_max = viewModel.maxZoomScale
            let max = min < full_max ? full_max : min

            Group {
                if let scale = currentZoomScale {
                    ZoomableView(
                      size: CGSize(
                        width: viewModel.frameWidth+outlierArrowLength*2,
                        height: viewModel.frameHeight+outlierArrowLength*2
                      ),
                      min: min,
                      max: max,
                      showsIndicators: true,
                      currentScale: Binding( // pass the optional currentZoomState
                        get: { scale },      // as not optional
                        set: { currentZoomScale = $0 }
                      )
                    ) {
                        self.imageView
                    }
                    // .zoomable(min: min, max: max, currentScale: $currentZoomScale)
                      .onAppear {
                          viewModel.minZoomScale = min
                          if viewModel.maxZoomScale < min {
                              viewModel.maxZoomScale = min
                          }
                      }
                      .onChange(of: geometry.size) {
                          Log.i("onChange(of: geometry.size \(geometry.size))")
                          if let currentZoomScale,
                             currentZoomScale != 1 // don't zoom out when we're already all the way in
                          {
                              withAnimation(.none) {
                                  self.currentZoomScale = min // make it full size
                              }
                          }
                      }
                      .onChange(of: currentZoomScale) {
                          Log.i("onChange(of: currentZoomScale \(currentZoomScale))")
                          if let currentZoomScale {
                              viewModel.currentZoomScale = currentZoomScale
                          }
                      }
                      .onChange(of: viewModel.currentZoomScale) {
                          Log.i("onChange(of: viewModel.currentZoomScale \(viewModel.currentZoomScale))")
                          currentZoomScale = viewModel.currentZoomScale
                      }
                      .onChange(of: viewModel.selectionMode) {
                          topViewModel.refreshCursor()
                      }
                      .onChange(of: viewModel.currentIndex) { oldValue, _ in
                          // add any changes the user may have made to the save queue
                          if oldValue >= 0,
                             oldValue < self.viewModel.frames.count
                          {
                              let frameView = self.viewModel.frames[oldValue]
                              Task {
                                  if let frameToSave = frameView.frame,
                                     await frameToSave.hasChanges()
                                  {
                                      await MainActor.run {
                                          self.viewModel.saveToFile(frame: frameToSave) {
                                              Log.d("saving frame \(frameToSave.frameIndex)")
                                              // await MainActor.run {
                                              await self.viewModel.refresh(frame: frameToSave)
                                              // }
                                          }
                                      }
                                  }
                              }
                          }
                      }
                } else {
                    Color.clear // placeholder for until we know the geometry
                      .onAppear {
                          // Sync viewModel.currentZoomScale before the ZoomableView
                          // first appears, so the imageView's horizon-overlay Canvas
                          // (which reads viewModel.currentZoomScale to compute a
                          // zoom-compensated lineWidth) renders correctly on the
                          // very first frame instead of using the stale default of 1.
                          currentZoomScale = min
                          viewModel.currentZoomScale = min
                      }
                }
            }
        }
        // ── Horizon-painter toolbar ───────────────────────────────────────
        // Placed here, *outside* the GeometryReader / ZoomableView, so it
        // renders at screen coordinates and is never scaled down with the image.
        .overlay(alignment: .bottom) {
            if viewModel.isShowingHorizonPainter, let ps = horizonPaintState {
                HorizonPainterToolbarView(paintState: ps)
            }
        }
        // ── Startup-mode instructions overlay ────────────────────────────
        .overlay(alignment: .top) {
            if viewModel.isShowingHorizonPainter,
               viewModel.horizonPainterMode == .startup
            {
                HorizonPainterStartupInstructionsView()
            }
        }
        // Create a fresh HorizonPaintState whenever the painter is opened,
        // and discard it when closed.
        .onChange(of: viewModel.isShowingHorizonPainter) { _, isShowing in
            if isShowing {
                loadHorizonPainterForCurrentFrame()
            } else {
                horizonPaintState = nil
            }
        }
        // During the startup moving-horizon flow the user advances through evenly-spaced
        // frames. Reset the painter state each time the frame changes so the user gets a
        // clean canvas for each new horizon.
        .onChange(of: viewModel.currentIndex) { _, _ in
            guard viewModel.isShowingHorizonPainter,
                  viewModel.horizonPainterMode == .startup
            else { return }
            resetPaintStateForCurrentFrame()
        }
    }

    /// Creates a fresh `HorizonPaintState` for the current frame and loads any
    /// existing reference horizon, transitioning straight to refinement if found.
    private func loadHorizonPainterForCurrentFrame() {
        let ps = HorizonPaintState(
            viewWidth:  viewModel.frameWidth,
            viewHeight: viewModel.frameHeight
        )
        ps.isErasing = viewModel.horizonPainterIsErasing
        ps.setPhase(.computing)
        horizonPaintState = ps
        loadHorizonReferenceInto(ps)
    }

    /// Resets the existing `HorizonPaintState` in place for the next frame in the
    /// startup multi-frame flow.  Preserves `brushRadius` so the user's tool
    /// setting carries over, and keeps the same instance reference so SwiftUI
    /// does not re-register keyboard shortcuts bound to the painter view.
    private func resetPaintStateForCurrentFrame() {
        guard let ps = horizonPaintState else {
            loadHorizonPainterForCurrentFrame()
            return
        }
        ps.resetForNewFrame()   // clears paint data, preserves brushRadius, sets .computing
        loadHorizonReferenceInto(ps)
    }

    /// Async-loads the saved horizon reference for the current frame into `ps`.
    private func loadHorizonReferenceInto(_ ps: HorizonPaintState) {
        let frameView = viewModel.currentFrameView
        let w = Int(viewModel.frameWidth)
        let h = Int(viewModel.frameHeight)

        Task { @MainActor in
            guard let frame = frameView.frame else {
                ps.setPhase(.bandSelection)
                return
            }
            if let existingY = try? await frame.loadBestExistingHorizonAsViewY(
                viewWidth:  w,
                viewHeight: h
            ) {
                let margin = max(50, h / 10)
                ps.loadExistingHorizon(existingY, margin: margin)
            } else {
                ps.setPhase(.bandSelection)
            }
        }
    }

    var imageView: some View {
        ZStack() {
            // the main image shown

            FrameEditImageView(frameViewModel: viewModel.frames[viewModel.currentIndex])
              .frame(width: viewModel.frameWidth, height: viewModel.frameHeight)

            // this is the selection overlay
            if let selectionStart = viewModel.selectionStart,
               let selectionEnd = viewModel.selectionEnd
            {
                let width = abs(selectionStart.x-selectionEnd.x)
                let height = abs(selectionStart.y-selectionEnd.y)

                let drag_x_offset = selectionEnd.x > selectionStart.x ? selectionStart.x : selectionEnd.x
                let drag_y_offset = selectionEnd.y > selectionStart.y ?  selectionStart.y : selectionEnd.y

                Rectangle()
                  .fill(viewModel.selectionColor.opacity(0.2))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 2))
                      .foregroundColor(viewModel.selectionColor.opacity(0.8))
                  )
                  .frame(width: width, height: height)
                  .offset(x: drag_x_offset - CGFloat(viewModel.frameWidth/2) + width/2,
                          y: drag_y_offset - CGFloat(viewModel.frameHeight/2) + height/2)
            }

            // Horizon line overlay — drawn when the right-panel toggle is on.
            // Uses full-frame-resolution yPerColumn so coordinates map 1:1 to
            // frame pixels. lineWidth is scaled by 1/zoom so the stroke stays
            // a constant visual thickness regardless of zoom level.
            if viewModel.userPreferences.showHorizonOnMainView ?? false,
               let overlay = viewModel.frames[viewModel.currentIndex].frameHorizonOverlay
            {
                let frameView = viewModel.frames[viewModel.currentIndex]
                let strokeColor: Color = if frameView.isPendingHorizonRefinement { .orange }
                else { switch overlay.kind {
                    case .initial:   .white
                    case .merged:    .blue
                    case .reference: .green
                }}
                let zoom = viewModel.currentZoomScale
                Canvas { ctx, size in
                    guard !overlay.yPerColumn.isEmpty else { return }
                    var path = Path()
                    for (col, y) in overlay.yPerColumn.enumerated() {
                        let pt = CGPoint(x: CGFloat(col), y: CGFloat(y))
                        if col == 0 { path.move(to: pt) }
                        else        { path.addLine(to: pt) }
                    }
                    ctx.stroke(path, with: .color(strokeColor), lineWidth: 4 / zoom)
                }
                .frame(width: viewModel.frameWidth, height: viewModel.frameHeight)
                .allowsHitTesting(false)
            }

            // Horizon painter canvas — overlaid at image coordinates so that
            // view-space brush strokes map directly to image pixels.
            // The toolbar is rendered outside the ZoomableView (see .overlay
            // in body) so it is never scaled down with the image.
            if viewModel.isShowingHorizonPainter, let ps = horizonPaintState {
                HorizonPainterView(paintState: ps)
                    .frame(width: viewModel.frameWidth, height: viewModel.frameHeight)
                    .transition(.opacity)
            }
        }
        //.highPriorityGesture(self.selectionDragGesture)
          .gesture(viewModel.isShowingHorizonPainter ? nil : self.selectionDragGesture)
          .cursor(self.currentCrosshairCursor)
    }

    func currentCrosshairCursor() -> NSCursor {
        switch viewModel.selectionMode {
        case .remove:
            .removeCrosshair
        case .keep:
            .keepCrosshair
        case .shovel:
            .shovelCrosshair
        case .razor:
            .razorCrosshair
            
        case .trash:
            .deleteTrashCrosshair
            
        case .removeFromTrash:
            .extractTrashCrosshair
        case .information:
            .infoCrosshair

        case .multi:
            .multiCrosshair

        case .none:
            .arrow
        }
    }
    
    var currentPointingCursor: NSCursor {
        switch viewModel.selectionMode {
        case .remove:
            .removePointing
        case .keep:
            .keepPointing
        case .shovel:
            .shovelPointing
        case .razor:
            .razorPointing
            
        case .trash:
            .deleteTrashPointing
            
        case .removeFromTrash:
            .extractTrashPointing
        case .information:
            .infoPointing

        case .multi:
            .multiPointing

        case .none:
            .arrow
        }
    }
    
    @State private var isDragging = false
    
    var selectionDragGesture: some Gesture {
        DragGesture()
          .onChanged { gesture in
              guard viewModel.currentFrameUsesOutliers else { return }
              let location = gesture.location
              if !isDragging { topViewModel.pushCursor(self.currentPointingCursor) }
              isDragging = true
              if viewModel.selectionStart != nil {
                  // updating during drag is too slow
                  viewModel.selectionEnd = location
              } else {
                  viewModel.selectionStart = gesture.startLocation
              }
              Log.v("location \(location)")
          }
          .onEnded { gesture in
              guard viewModel.currentFrameUsesOutliers else { return }
              topViewModel.popCursor()
              isDragging = false
              let end_location = gesture.location
              if let selectionStart = viewModel.selectionStart {
                  Log.v("end location \(end_location) drag start \(selectionStart)")
                  
                  let frameView = viewModel.currentFrameView
                  
                  switch viewModel.selectionMode {
                  case .remove:
                      update(frame: frameView, shouldRemove: true,
                             between: selectionStart, and: end_location)
                      
                  case .keep:
                      update(frame: frameView, shouldRemove: false,
                             between: selectionStart, and: end_location)
                      
                  case .shovel:
                      Log.d("applying shovel")
                      applyShovel(to: frameView,
                                  between: selectionStart,
                                  and: end_location)
                      {
                          if let frame = frameView.frame {
                              // recompute small outlier images after the shovel
                              Task { 
                                  frameView.computeSmallOutlierImage()
                                  await frame.markAsChanged()
                              }
                              
                              // if we are showing the trash, recompute the image after the shovel
                              if viewModel.shouldShowTrash {
                                  frameView.computeTrashImage()
                              }
                          }
                      }
                      
                  case .razor:
                      applyRazor(to: frameView,
                                 between: selectionStart,
                                 and: end_location)

                     
                          // recompute small outlier images after the razor
                          frameView.computeSmallOutlierImage()
                          
                          // if we are showing the trash, recompute the image after the razor
                          if viewModel.shouldShowTrash {
                              frameView.computeTrashImage()
                          }
                      
                      
                  case .trash:
                      dumpInTrash(from: frameView,
                                    between: selectionStart,
                                    and: end_location) 
                      
                  case .removeFromTrash:
                      extractDust(from: frameView,
                                  between: selectionStart,
                                  and: end_location) 

                  case .information:
                      //let _ = Log.d("DETAILS")

                      if let frame = frameView.frame {
                          Task {
                              //var new_outlier_info: [OutlierGroup] = []
                              let _outlierGroupTableRows = ArrayActor<OutlierGroupTableRow>()
                              
                              await frame.foreachOutlierGroupMulti(between: selectionStart,
                                                                   and: end_location,
                                                                   includingTrash: viewModel.shouldShowTrash) { group, isInTrash in // XXX isInTrash not presented in UI
                                  let new_row = await OutlierGroupTableRow(group)
                                  await _outlierGroupTableRows.append(new_row)
                                  return false
                              }
                              var elements = await _outlierGroupTableRows.getElements()
                              elements.sort { $0.size > $1.size }
                              await MainActor.run {
                                  self.viewModel.outlierGroupWindowFrame = frame
                                  self.viewModel.outlierGroupTableRows = elements
                                  //Log.d("outlierGroupTableRows \(viewModel.outlierGroupTableRows.count)")
                                  if self.viewModel.shouldShowOutlierGroupTableWindow() {
                                      openWindow(id: StarApp.outlierGroupTableWindowName) 
                                  }

                                  viewModel.selectionStart = nil
                                  viewModel.selectionEnd = nil
                              }
                          }
                      } 

                  case .multi:
                      self.viewModel.multiSelectSheetShowing = true

                  case .none:
                      // do nothing
                      break
                  }
              }
         }
    }

    private func applyShovel(to frameView: FrameViewModel,
                             between selectionStart: CGPoint,
                             and end_location: CGPoint,
                             completion: @escaping () -> Void)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        if let frame = frameView.frame {
            Log.d("shoveling frame \(frame.frameIndex) @ \(gestureBounds)")
            Task {
                await Task.detached(priority: .userInitiated) {
                    await shovelFrame(to: frame, in: gestureBounds, with: viewModel)
                }.value
                Task { @MainActor in 
                    completion()
                    viewModel.selectionStart = nil
                    viewModel.selectionEnd = nil
                }
            }
        }
    }
    
    private func applyRazor(to frameView: FrameViewModel,
                            between selectionStart: CGPoint,
                            and end_location: CGPoint)
    {
        let gestureBounds = BoundingBox(between: selectionStart, and: end_location)

        if let frame = frameView.frame {
            Task.detached(priority: .userInitiated) {
                try await frame.applyRazor(in: gestureBounds,
                                           includingTrash: viewModel.shouldShowTrash)
                await frameView.setOutlierGroups()
                await MainActor.run {
                    viewModel.selectionStart = nil
                    viewModel.selectionEnd = nil
                }
            }
        } else {
            viewModel.selectionStart = nil
            viewModel.selectionEnd = nil
        }
    }

    // takes outliers from the view layer and dumps them in the trash
    private func dumpInTrash(from frameView: FrameViewModel,
                               between selectionStart: CGPoint,
                               and end_location: CGPoint)
    {
        frameView.dumpInTrash(between: selectionStart, and: end_location)
        viewModel.selectionStart = nil
        viewModel.selectionEnd = nil
    }

    // promotes outliers from trash to the view layer
    private func extractDust(from frameView: FrameViewModel,
                             between selectionStart: CGPoint,
                             and end_location: CGPoint)
    {
        frameView.extractDust(between: selectionStart, and: end_location)
        viewModel.selectionStart = nil
        viewModel.selectionEnd = nil
    }
    
    private func update(frame frameView: FrameViewModel,
                        shouldRemove: Bool,
                        between selectionStart: CGPoint,
                        and end_location: CGPoint)
    {
        if let frame = frameView.frame {
            let new_value = shouldRemove
            Task.detached(priority: .userInitiated) {
                await frame.userSelectAllOutliers(toShouldRemove: new_value,
                                                  between: selectionStart,
                                                  and: end_location,
                                                  includingTrash: viewModel.shouldShowTrash)
                await frameView.setOutlierGroups()
                
                await frameView.computeSmallOutlierImage()
                
                // if we are showing the trash, recompute the image
                if await viewModel.shouldShowTrash {
                    await frameView.computeTrashImage()
                }
                
                await MainActor.run {
                    viewModel.selectionStart = nil
                    viewModel.selectionEnd = nil
                }
            }
        } else {
            viewModel.selectionStart = nil
            viewModel.selectionEnd = nil
        }
    }
}

// MARK: - Horizon painter startup instructions

struct HorizonPainterStartupInstructionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @State private var isDismissed = false
    @State private var dontShowAgain = false

    private var isMoving: Bool {
        viewModel.horizonPainterStartupFrameIndices.count > 1
    }

    var body: some View {
        if !isDismissed && (viewModel.userPreferences.showHorizonPainterInstructions ?? true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Selecting the horizon with Star is easy.")
                  .font(.headline)
                  .foregroundColor(.white)

                if isMoving {
                    Text("""
For a moving video like this, you can define the horizon on several evenly-spaced frames. Star will use these as references for all frames in the sequence.  This makes overall processing faster and more accurate.

If the frame shown here doesn't show the horizon well, you can scroll to a different frame in the sequence to use instead.

Then brush over the horizon itself, so that the selected area covers the horizon line itself.  Once you have selected across the entire width of the screen, Star will then automatically try to select the sky part of the image, stopping at what it thinks is the horizon.

If the selection looks good, hit 'Continue'.

If the selection of the sky isn't exactly right, use the brush to either add or remove to the selection.  Use '[' and ']' keys to shrink and enlarge the brush.
""")
                      .font(.body)
                      .foregroundColor(.white)
                } else {
                    Text("""
For a static video like this, you can choose any frame to calculate a horizon from and Star can then apply that same horizon mask to all frames in the sequence.  This makes overall processing faster and more accurate.

If the frame you see here doesn't show the horizon well, scroll to a different frame that does first.

Then brush over the horizon itself, so that the selected area covers the horizon line itself.  Once you have selected across the entire width of the screen, Star will then automatically try to select the sky part of the image, stopping at what it thinks is the horizon.

If the selection looks good, hit 'Continue'.

If the selection of the sky isn't exactly right, use the brush to either add or remove to the selection.  Use '[' and ']' keys to shrink and enlarge the brush.
""")
                      .font(.body)
                      .foregroundColor(.white)
                }

                HStack(spacing: 16) {
                    Toggle("Don't show again", isOn: $dontShowAgain)
                      .foregroundColor(.white)

                    Button("Got it") {
                        if dontShowAgain {
                            viewModel.userPreferences.showHorizonPainterInstructions = false
                        }
                        withAnimation { isDismissed = true }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                  .fill(Color.black.opacity(0.75))
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .transition(.opacity)
        }
    }
}

// re-process within the given bounds
func shovelFrame(to frame: FrameAirplaneRemover,
                 in gestureBounds: BoundingBox,
                 with viewModel: ImageSequenceViewModel) async
{
    Log.d("shovel frame \(frame.frameIndex)")
    do {
        // discards any existing outlier pixels that are within the given bounds
        try await frame.findOutliers(within: gestureBounds)
        await Task { @MainActor in
            let frameView = viewModel.frames[frame.frameIndex]
            frameView.outlierViews = nil
            
            await frameView.setOutlierGroups()
        }.value
        await frame.set(state: .complete)
    } catch {
        Log.e("error finding outliers for frame \(frame.frameIndex): \(error)")
    }

}
