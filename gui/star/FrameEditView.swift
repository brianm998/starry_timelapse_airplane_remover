import SwiftUI
import StarCore

// the view for when the user wants to edit what outlier groups are painted and not

struct FrameEditView: View {
    @ObservedObject var viewModel: ViewModel
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
        ZStack {
            // the main image shown
            image

            if interactionMode == .edit {
                // in edit mode, show outliers groups 
                let current_frame_view = viewModel.currentFrameView
                if let outlierViews = current_frame_view.outlierViews {
                    ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                        if idx < outlierViews.count {
                            // the actual outlier view
                            outlierViews[idx].body
                        }
                    }
                }
            }

            // this is the selection overlay
            if isDragging,
               let drag_start = drag_start,
               let drag_end = drag_end
            {
                let width = abs(drag_start.x-drag_end.x)
                let height = abs(drag_start.y-drag_end.y)

                let _ = Log.d("drag_start \(drag_start) drag_end \(drag_end) width \(width) height \(height)")

                let drag_x_offset = drag_end.x > drag_start.x ? drag_end.x : drag_start.x
                let drag_y_offset = drag_end.y > drag_start.y ? drag_end.y : drag_start.y

                Rectangle()
                  .fill(viewModel.selectionColor.opacity(0.2))
                  .overlay(
                    Rectangle()
                      .stroke(style: StrokeStyle(lineWidth: 2))
                      .foregroundColor(viewModel.selectionColor.opacity(0.8))
                  )                
                  .frame(width: width, height: height)
                  .offset(x: CGFloat(-viewModel.frame_width/2) + drag_x_offset - width/2,
                          y: CGFloat(-viewModel.frame_height/2) + drag_y_offset - height/2)
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
              //Log.d("location \(location)")
          }
          .onEnded { gesture in
              isDragging = false
              let end_location = gesture.location
              if let drag_start = drag_start {
                  Log.d("end location \(end_location) drag start \(drag_start)")
                  
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
                      if let frame = frameView.frame {
                          Task {
                              // is view layer updated? (NO)
                              await frame.userSelectAllOutliers(toShouldPaint: should_paint,
                                                                between: drag_start,
                                                                and: end_location)
                              viewModel.update()
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
                                  self.viewModel.showOutlierGroupTableWindow()
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
