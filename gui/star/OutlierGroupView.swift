import Foundation
import SwiftUI
import Cocoa
import StarCore

// the view for a single outlier group on a frame

struct OutlierGroupView: View {
    @Environment(\.openWindow) private var openWindow

    @ObservedObject var groupViewModel: OutlierGroupViewModel

    var body: some View {
        // .bottomLeading alignment is used to avoid a bug in .onHover and onTap
        // which is described in more detail in FrameEditView
        ZStack(alignment: .bottomLeading) {
            let frame_width = CGFloat(self.groupViewModel.frame_width)
            let frame_height = CGFloat(self.groupViewModel.frame_height)
            let bounds = self.groupViewModel.bounds
            let will_paint = self.groupViewModel.willPaint ?? false
            let paint_color = self.groupViewModel.selectionColor
            let arrow_length = self.arrowLength
            let arrow_height = self.arrowHeight
            let line_width = self.lineWidth
            let center_x = CGFloat(bounds.center.x)
            let center_y = CGFloat(bounds.center.y)

            // this centers the arrows on the lines
            let fiddle = arrow_height/2 - line_width/2
            
            if will_paint {
                // arrow indicators on the side of the image

                // arrow on left side
                arrowImage(named: "arrow.right")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: -arrow_length,
                          y: center_y - frame_height + fiddle)

                // arrow on top
                arrowImage(named: "arrow.down")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - fiddle,
                          y: -frame_height)

                // arrow on right side
                arrowImage(named: "arrow.left")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: frame_width,
                          y: center_y - frame_height + fiddle)

                // arrow on bottom 
                arrowImage(named: "arrow.up")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - fiddle, y: arrow_length)


                // lines across the frame between the arrows and outlier group bounds
                if self.groupViewModel.arrowSelected {
                    let left_line_width = CGFloat(bounds.center.x - bounds.width/2)

                    let right_line_width = CGFloat(groupViewModel.frame_width) -
                      left_line_width - CGFloat(bounds.width)

                    let top_line_height = CGFloat(bounds.center.y - bounds.height/2)

                    let bottom_line_height = CGFloat(groupViewModel.frame_height) -
                      top_line_height - CGFloat(bounds.height)

                    // left line
                    outlierFrameLine()
                      .frame(width: left_line_width,
                             height: line_width)
                      .offset(x: 0, y: CGFloat(bounds.center.y) - frame_height)

                    // top line 
                    outlierFrameLine()
                      .frame(width: line_width,
                             height: top_line_height)
                      .offset(x: CGFloat(bounds.center.x),
                              y: CGFloat(bounds.min.y)-frame_height)

                    // right line
                    outlierFrameLine()
                      .frame(width: right_line_width,
                             height: line_width)
                      .offset(x: CGFloat(bounds.max.x),
                              y: CGFloat(bounds.center.y) - frame_height)

                    // bottom line
                    outlierFrameLine()
                      .frame(width: line_width,
                             height: bottom_line_height)
                      .offset(x: CGFloat(bounds.center.x), y: 0)
                }
            }
            ZStack(alignment: .bottomLeading) {
                if self.groupViewModel.arrowSelected {
                    // underlay for when this outlier group is hovered over
                    Rectangle()
                      .foregroundColor(will_paint ? .purple : .yellow)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/4)
                      .contentShape(Rectangle())
                }
                // the actual outlier group image
                Image(nsImage: self.groupViewModel.image)
                  .renderingMode(.template) // makes this VV color work
                  .foregroundColor(paint_color)
                  .contentShape(Rectangle())
                  .blendMode(.hardLight)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
            }
              .offset(x: CGFloat(bounds.min.x),
                      y: CGFloat(bounds.min.y) - frame_height + CGFloat(bounds.height))
              .frame(width: CGFloat(bounds.width),
                     height: CGFloat(bounds.height))
              .onHover { self.groupViewModel.arrowSelected = $0 }
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if let origShouldPaint = self.groupViewModel.group.shouldPaint {
                      // change the paintability of this outlier group
                      // set it to user selected opposite previous value
                      Task {
                          if self.groupViewModel.viewModel.selectionMode == .details {
                              Log.w("DETAILS")
                              // here we want to select just this outlier

                              if self.groupViewModel.viewModel.outlierGroupTableRows.count == 1,
                                 self.groupViewModel.viewModel.outlierGroupTableRows[0].name == self.groupViewModel.group.name
                              {
                                  // just toggle the selectablility of this one
                                  // XXX need separate enums for selection does paint and selection does do info
                              } else {
                                  // make this row the only selected one
                                  let frame_view = self.groupViewModel.viewModel.frames[self.groupViewModel.group.frame_index]
                                  if let frame = frame_view.frame,
                                     let group = frame.outlierGroup(named: self.groupViewModel.group.name)
                                  {
                                      if let outlier_views = frame_view.outlierViews {
                                          for outlier_view in outlier_views {
                                              if outlier_view.name != self.groupViewModel.group.name {
                                                  outlier_view.isSelected = false
                                              }
                                          }
                                      }
                                      let new_row = await OutlierGroupTableRow(group)
                                      self.groupViewModel.isSelected = true
                                      await MainActor.run {
                                          self.groupViewModel.viewModel.outlierGroupWindowFrame = frame
                                          self.groupViewModel.viewModel.outlierGroupTableRows = [new_row]
                                          self.groupViewModel.viewModel.selectedOutliers = [new_row.id]

                                          if self.groupViewModel.viewModel.shouldShowOutlierGroupTableWindow() {
                                              openWindow(id: "foobar") 
                                          }

                                          self.groupViewModel.viewModel.update()

                                      }
                                  } else {
                                      Log.w("couldn't find frame")
                                  }
                              }
                              
                          } else {
                              togglePaintReason(origShouldPaint)
                          }
                          // update the view model so it shows up on screen
                      }
                  } else {
                      Log.e("WTF, not already set to paint??")
                  }
              }
        }
    }

    func togglePaintReason(_ origShouldPaint: PaintReason) {
        let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
        
        // update the view model to show the change quickly
        self.groupViewModel.group.shouldPaint = reason
        self.groupViewModel.objectWillChange.send() 

        Task {
            if let frame = self.groupViewModel.viewModel.currentFrame,
               let outlier_groups = frame.outlier_groups,
               let outlier_group = outlier_groups.members[self.groupViewModel.group.name]
            {
                // update the actor in the background
                await outlier_group.shouldPaint(reason)
                self.groupViewModel.viewModel.update()
            } else {
                Log.e("HOLY FUCK")
            }
        }
    }

    // images for arrows at edge of frame that point towards outlier groups
    private func arrowImage(named imageName: String) -> some View {
        Image(systemName: imageName)
          .resizable()
          .foregroundColor(.purple)
          .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
          .onHover { self.groupViewModel.arrowSelected = $0 }
          .onTapGesture {
              if let shouldPaint = self.groupViewModel.group.shouldPaint {
                  togglePaintReason(shouldPaint)
              }
          }
    }

    public func outlierFrameLine() -> some View {
        Rectangle()
          .foregroundColor(.purple)
          .blendMode(.difference)
          .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
    }
    
    private var arrowLength: CGFloat {
        let frame_width = CGFloat(self.groupViewModel.frame_width)
        return frame_width/40
    }

    private var arrowHeight: CGFloat {
        let frame_width = CGFloat(self.groupViewModel.frame_width)
        return frame_width/300
    }
    
    private var lineWidth: CGFloat { self.arrowHeight/4 }
}

