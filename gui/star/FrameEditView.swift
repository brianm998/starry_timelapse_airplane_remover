import SwiftUI
import StarCore
import Zoomable
import logging

// the view for when the user wants to edit what outlier groups are painted and not

struct FrameEditView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Environment(\.openWindow) private var openWindow

    let image: Image
    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    @State private var isDragging = false

    public init(image: Image,
               interactionMode: Binding<InteractionMode>,
               showFullResolution: Binding<Bool>)
    {
        self.image = image
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
              //.transition(.moveAndFade)
        }
    }
    
    var imageView: some View {
        // alignment is .bottomLeading because of the bug outlined below
        ZStack(alignment: .bottomLeading) {
            // the main image shown
            image
              .frame(width: viewModel.frameWidth, height: viewModel.frameHeight)
            if interactionMode == .edit {
                Group {
                    // in edit mode, show outliers groups 
                    let current_frame_view = viewModel.currentFrameView
                    if let outlierViews = current_frame_view.outlierViews {
                        ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                            if idx < outlierViews.count {
                                // the actual outlier view
                                outlierViews[idx].view
                            }
                        }
                    }
                }.opacity(viewModel.outlierOpacity)
            }

            /*
             this is a transparent rectangle at the bottom left of the screen
             which is necessary to avoid a bug in onHover { } for the outlier groups

             this bug appears when a user hovers close to the natural placement in the
             parent view for an outlier group, even when that view has been offset to a
             different location.  This bug then fires onHover { } for two locations for each
             outlier group, with most of them clustered in the default placement, which
             here is dictated by alignment: .bottomLeading
             both in the ZStack above and in the outlier group views inside
             */
            Rectangle()
              .foregroundColor(.clear)
              .frame(width: 1200, height: 800) // XXX arbitrary constants, could use screen size?
              .onHover { _ in }



            // this is the selection overlay
            if isDragging || viewModel.multiSelectSheetShowing,
               let drag_start = viewModel.drag_start,
               let drag_end = viewModel.drag_end
            {
                let width = abs(drag_start.x-drag_end.x)
                let height = abs(drag_start.y-drag_end.y)

                let _ = Log.v("drag_start \(drag_start) drag_end \(drag_end) width \(width) height \(height)")

                let drag_x_offset = drag_end.x > drag_start.x ? drag_start.x : drag_end.x
                let drag_y_offset = drag_end.y > drag_start.y ?  drag_start.y : drag_end.y

                Rectangle()
                  .fill(viewModel.selectionColor.opacity(0.2))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 2))
                      .foregroundColor(viewModel.selectionColor.opacity(0.8))
                  )                
                  .frame(width: width, height: height)
                  .offset(x: drag_x_offset,
                          y: CGFloat(-viewModel.frameHeight) + drag_y_offset + height)
            }
        }
        // XXX selecting and zooming conflict with eachother
          .gesture(self.selectionDragGesture)
    }

    var selectionDragGesture: some Gesture {
        DragGesture()
          .onChanged { gesture in
              let _ = Log.d("isDragging")
              isDragging = true
              let location = gesture.location
              if viewModel.drag_start != nil {
                  // updating during drag is too slow
                  viewModel.drag_end = location
              } else {
                  viewModel.drag_start = gesture.startLocation
              }
              Log.v("location \(location)")
          }
          .onEnded { gesture in
              isDragging = false
              let end_location = gesture.location
              if let drag_start = viewModel.drag_start {
                  Log.v("end location \(end_location) drag start \(drag_start)")
                  
                  let frameView = viewModel.currentFrameView
                  
                  switch viewModel.selectionMode {
                  case .paint:
                      update(frame: frameView, shouldPaint: true,
                             between: drag_start, and: end_location)
                  case .clear:
                      update(frame: frameView, shouldPaint: false,
                             between: drag_start, and: end_location)
                  case .delete:
                      let _ = Log.d("DELETE")
                      deleteOutliers(frame: frameView,
                                     between: drag_start,
                                     and: end_location) 

                  case .details:
                      let _ = Log.d("DETAILS")

                      if let frame = frameView.frame {
                          Task {
                              //var new_outlier_info: [OutlierGroup] = []
                              var _outlierGroupTableRows: [OutlierGroupTableRow] = []
                              
                              await frame.foreachOutlierGroup(between: drag_start,
                                                              and: end_location) { group in
                                  Log.d("group \(group)")
                                  //new_outlier_info.append(group)

                                  let new_row = await OutlierGroupTableRow(group)
                                  _outlierGroupTableRows.append(new_row)
                                  return .continue
                              }
                              await MainActor.run {
                                  self.viewModel.outlierGroupWindowFrame = frame
                                  self.viewModel.outlierGroupTableRows = _outlierGroupTableRows
                                  Log.d("outlierGroupTableRows \(viewModel.outlierGroupTableRows.count)")
                                  if self.viewModel.shouldShowOutlierGroupTableWindow() {
                                      openWindow(id: "foobar") 
                                  }

                                  viewModel.drag_start = nil
                                  viewModel.drag_end = nil
                              }
                          }
                      } 

                  case .multi:
                      self.viewModel.multiSelectSheetShowing = true
                      //self.viewModel.drag_start = $viewModel.drag_start
                      self.viewModel.drag_end = end_location
                  }
              }
          }
    }


    private func deleteOutliers(frame frameView: FrameViewModel,
                                between drag_start: CGPoint,
                                and end_location: CGPoint)
    {
        // update the view on the main thread
        let gestureBounds = frameView.deleteOutliers(between: drag_start, and: end_location)
        
        if let frame = frameView.frame {
            Task.detached(priority: .userInitiated) {
                // update the frame in the background
                try frame.deleteOutliers(in: gestureBounds) // XXX errors not handled
                await MainActor.run {
                    viewModel.drag_start = nil
                    viewModel.drag_end = nil
                   
                }
            }
        }
    }

    private func update(frame frameView: FrameViewModel,
                        shouldPaint: Bool,
                        between drag_start: CGPoint,
                        and end_location: CGPoint)
    {
        frameView.userSelectAllOutliers(toShouldPaint: shouldPaint,
                                        between: drag_start,
                                        and: end_location)
        {
            viewModel.drag_start = nil
            viewModel.drag_end = nil
        }

      
       
        if let frame = frameView.frame {
            let new_value = shouldPaint
            Task.detached(priority: .userInitiated) {
                await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                  between: drag_start,
                                                  and: end_location)
               
            }
        }

    }
}
