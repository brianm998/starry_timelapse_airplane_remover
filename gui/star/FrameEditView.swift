import SwiftUI
import StarCore
import Zoomable
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

    var body: some View {
        // wrap the frame view with a zoomable view
        GeometryReader { geometry in
            // this is to account for the outlier arrows on the sides of the frame
            let outlierArrowLength = self.viewModel.frameWidth/self.viewModel.outlierArrowLength
            
            let min = (geometry.size.height/(viewModel.frameHeight+outlierArrowLength*2))
            let full_max: CGFloat = self.viewModel.showFullResolution ? 3 : 0.66 // XXX hardcoded constants that should be in the gui
            let max = min < full_max ? full_max : min

            ZoomableView(size: CGSize(width: viewModel.frameWidth+outlierArrowLength*2,
                                      height: viewModel.frameHeight+outlierArrowLength*2),
                         min: min,
                         max: max,
                         showsIndicators: true)
            {
                // the currently visible frame
                self.imageView
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
        }
    }
    
    var imageView: some View {
        ZStack() {
            // the main image shown

            FrameEditImageView()
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
        }
          .gesture(self.selectionDragGesture)
          .cursor(self.currentCrosshairCursor)
    }

    var currentCrosshairCursor: NSCursor {
        switch viewModel.selectionMode {
        case .remove:
            return .removeCrosshair
        case .keep:
            return .keepCrosshair
        case .shovel:
            return .shovelCrosshair
        case .razor:
            return .razorCrosshair
            
        case .trash:
            return .deleteTrashCrosshair
            
        case .removeFromTrash:
            return .extractTrashCrosshair
        case .information:
            return .infoCrosshair

        case .multi:
            return .multiCrosshair

        }
    }
    
    var currentPointingCursor: NSCursor {
        switch viewModel.selectionMode {
        case .remove:
            return .removePointing
        case .keep:
            return .keepPointing
        case .shovel:
            return .shovelPointing
        case .razor:
            return .razorPointing
            
        case .trash:
            return .deleteTrashPointing
            
        case .removeFromTrash:
            return .extractTrashPointing
        case .information:
            return .infoPointing

        case .multi:
            return .multiPointing

        }
    }
    
    @State private var isDragging = false
    
    var selectionDragGesture: some Gesture {
        DragGesture()
          .onChanged { gesture in
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
                                  self.viewModel.computeSmallOutlierImage(forFrame: frame)
                                  await frame.markAsChanged()
                              }
                              
                              // if we are showing the trash, recompute the image after the shovel
                              if viewModel.shouldShowTrash {
                                  self.viewModel.computeTrashImage(forFrame: frame)
                              }
                          }
                      }
                      
                  case .razor:
                      applyRazor(to: frameView,
                                 between: selectionStart,
                                 and: end_location)

                      if let frame = frameView.frame {
                          // recompute small outlier images after the razor
                          Task { 
                              await self.viewModel.computeSmallOutlierImage(forFrame: frame)
                          }
                          
                          // if we are showing the trash, recompute the image after the razor
                          if viewModel.shouldShowTrash {
                              self.viewModel.computeTrashImage(forFrame: frame)
                          }
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
                await viewModel.setOutlierGroups(forFrame: frame)
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
                await viewModel.setOutlierGroups(forFrame: frame)
                
                await self.viewModel.computeSmallOutlierImage(forFrame: frame)
                
                // if we are showing the trash, recompute the image
                if await viewModel.shouldShowTrash {
                    if let frame = await frameView.frame {
                        await self.viewModel.computeTrashImage(forFrame: frame)
                    }
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
