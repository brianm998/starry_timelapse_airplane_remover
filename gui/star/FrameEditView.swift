import SwiftUI
import StarCore

// the view for when the user wants to edit what outlier groups are painted and not

struct FrameEditView: View {
    @ObservedObject var viewModel: ViewModel
    @Environment(\.openWindow) private var openWindow

    let image: Image
    @Binding private var interactionMode: InteractionMode

    @State private var isDragging = false
    @State private var drag_start: CGPoint?
    @State private var drag_end: CGPoint?

    public init(viewModel: ViewModel,
                image: Image,
                interactionMode: Binding<InteractionMode>)
    {
        self.viewModel = viewModel
        self.image = image
        _interactionMode = interactionMode
    }
    
    var body: some View {
        // alignment is .bottomLeading because of the bug outlied below
        ZStack(alignment: .bottomLeading) {
            // the main image shown
            image
              .frame(width: viewModel.frame_width, height: viewModel.frame_height)
            if interactionMode == .edit {
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
            if isDragging,
               let drag_start = drag_start,
               let drag_end = drag_end
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
                          y: CGFloat(-viewModel.frame_height) + drag_y_offset + height)
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
              if drag_start != nil {
                  // updating during drag is too slow
                  drag_end = location
              } else {
                  drag_start = gesture.startLocation
              }
              Log.v("location \(location)")
          }
          .onEnded { gesture in
              isDragging = false
              let end_location = gesture.location
              if let drag_start = drag_start {
                  Log.v("end location \(end_location) drag start \(drag_start)")
                  
                  let frameView = viewModel.currentFrameView
                  
                  var should_paint = false
                  var paint_choice = true
                  
                  switch viewModel.selectionMode {
                  case .paint:
                      should_paint = true
                  case .clear:
                      should_paint = false
                  case .details:
                      paint_choice = false
                  }
                  
                  if paint_choice {
                      frameView.userSelectAllOutliers(toShouldPaint: should_paint,
                                                      between: drag_start,
                                                      and: end_location)
                      //update the view layer
                      frameView.update()
                      if let frame = frameView.frame {
                          let new_value = should_paint
                          Task.detached {
                              await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                                between: drag_start,
                                                                and: end_location)
                          }
                      }
                  } else {
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
                              }
                          }
                      } 
                      
                      // XXX show the details here somehow
                  }
              }
              drag_start = nil
              drag_end = nil
          }
    }
}
