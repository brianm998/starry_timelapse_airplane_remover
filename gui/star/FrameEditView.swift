import SwiftUI
import StarCore
import Zoomable
import logging

// the view for when the user wants to edit what outlier groups are painted and not

struct FrameEditView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Environment(\.openWindow) private var openWindow

    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    public init(interactionMode: Binding<InteractionMode>,
                showFullResolution: Binding<Bool>)
    {
        _interactionMode = interactionMode
        _showFullResolution = showFullResolution
    }

    var body: some View {
        // wrap the frame view with a zoomable view
        GeometryReader { geometry in
            // this is to account for the outlier arrows on the sides of the frame
            let outlierArrowLength = self.viewModel.frameWidth/self.viewModel.outlierArrowLength
            
            let min = (geometry.size.height/(viewModel.frameHeight+outlierArrowLength*2))
            let full_max = self.showFullResolution ? 1 : 0.3
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
                      if let frameToSave = frameView.frame,
                         frameToSave.hasChanges()
                      {
                          Task {
                              self.viewModel.saveToFile(frame: frameToSave) {
                                  Log.d("saving frame \(frameToSave.frameIndex)")
                                  self.viewModel.refresh(frame: frameToSave)
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

            FrameImageView(interactionMode: self.$interactionMode,
                           showFullResolution: self.$showFullResolution)
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
        // XXX selecting and zooming conflict with eachother
          .gesture(self.selectionDragGesture)
    }

    var selectionDragGesture: some Gesture {
        DragGesture()
          .onChanged { gesture in
              let location = gesture.location
              if viewModel.selectionStart != nil {
                  // updating during drag is too slow
                  viewModel.selectionEnd = location
              } else {
                  viewModel.selectionStart = gesture.startLocation
              }
              Log.v("location \(location)")
          }
          .onEnded { gesture in
              let end_location = gesture.location
              if let selectionStart = viewModel.selectionStart {
                  Log.v("end location \(end_location) drag start \(selectionStart)")
                  
                  let frameView = viewModel.currentFrameView
                  
                  switch viewModel.selectionMode {
                  case .paint:
                      update(frame: frameView, shouldPaint: true,
                             between: selectionStart, and: end_location)
                  case .clear:
                      update(frame: frameView, shouldPaint: false,
                             between: selectionStart, and: end_location)
                  case .delete:
                      //let _ = Log.d("DELETE")
                      deleteOutliers(frame: frameView,
                                     between: selectionStart,
                                     and: end_location) 

                  case .details:
                      //let _ = Log.d("DETAILS")

                      if let frame = frameView.frame {
                          Task {
                              //var new_outlier_info: [OutlierGroup] = []
                              var _outlierGroupTableRows: [OutlierGroupTableRow] = []
                              
                              frame.foreachOutlierGroup(between: selectionStart,
                                                        and: end_location) { group in
                                  let new_row = OutlierGroupTableRow(group)
                                  _outlierGroupTableRows.append(new_row)
                                  return .continue
                              }
                              await MainActor.run {
                                  self.viewModel.outlierGroupWindowFrame = frame
                                  self.viewModel.outlierGroupTableRows = _outlierGroupTableRows
                                  //Log.d("outlierGroupTableRows \(viewModel.outlierGroupTableRows.count)")
                                  if self.viewModel.shouldShowOutlierGroupTableWindow() {
                                      openWindow(id: "foobar") 
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


    private func deleteOutliers(frame frameView: FrameViewModel,
                                between selectionStart: CGPoint,
                                and end_location: CGPoint)
    {
        // update the view on the main thread
        let gestureBounds = frameView.deleteOutliers(between: selectionStart, and: end_location)
        
        if let frame = frameView.frame {
            Task.detached(priority: .userInitiated) {
                // update the frame in the background
                try frame.deleteOutliers(in: gestureBounds) // XXX errors not handled
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

    private func update(frame frameView: FrameViewModel,
                        shouldPaint: Bool,
                        between selectionStart: CGPoint,
                        and end_location: CGPoint)
    {
        if let frame = frameView.frame {
            let new_value = shouldPaint
            Task.detached(priority: .userInitiated) {
                frame.userSelectAllOutliers(toShouldPaint: new_value,
                                            between: selectionStart,
                                            and: end_location)
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
