import Foundation
import SwiftUI
import Cocoa
import StarCore

// the view for a single outlier group on a frame

struct OutlierGroupView: View {
    @ObservedObject var groupViewModel: OutlierGroupViewModel

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            let frame_width = CGFloat(self.groupViewModel.frame_width)
            let frame_height = CGFloat(self.groupViewModel.frame_height)

            let outlier_center = self.groupViewModel.bounds.center
            let outlier_min = self.groupViewModel.bounds.min
            let outlier_max = self.groupViewModel.bounds.max
            
            let will_paint = self.groupViewModel.willPaint ?? false
            
            let paint_color = self.groupViewModel.selectionColor

            let arrow_length = frame_width/20
            let arrow_height = frame_width/300

            let line_width = arrow_height/4

            // this centers the arrows on the lines
            let fiddle = arrow_height/2 - arrow_height/8
            
            if will_paint {
                // arrow indicators on the side of the image

                // left arrow
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: -arrow_length,
                          y: CGFloat(outlier_center.y) - frame_height + fiddle)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // top arrow
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - fiddle,
                          y: -frame_height)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // right arrow
                Rectangle()
                  .foregroundColor(.purple)
                  .offset(x: frame_width,
                          y: CGFloat(outlier_center.y) - frame_height + fiddle)
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // bottom arrow
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - fiddle, y: arrow_length)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }


                // lines across the frame between the arrows and outlier group bounds
                if self.groupViewModel.arrowSelected {
                    let width_1 = CGFloat(outlier_center.x - self.groupViewModel.bounds.width/2)

                    let height_1 = CGFloat(outlier_center.y - self.groupViewModel.bounds.height/2)

                    let height_2 = CGFloat(groupViewModel.frame_height) -
                      height_1 - CGFloat(self.groupViewModel.bounds.height)

                    let width_2 = CGFloat(groupViewModel.frame_width) -
                      width_1 -
                      CGFloat(self.groupViewModel.bounds.width)

                    // left line
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: width_1,
                             height: line_width)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: 0, y: CGFloat(outlier_center.y) - frame_height)

                    // top line 
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: line_width,
                             height: height_1)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: CGFloat(outlier_center.x),
                              y: CGFloat(outlier_min.y)-frame_height)

                    // right line
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: width_2,
                             height: line_width)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: CGFloat(outlier_max.x),
                              y: CGFloat(outlier_center.y) - frame_height)

                    // bottom line
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: line_width,
                             height: height_2)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: CGFloat(outlier_center.x), y: 0)
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
                Image(nsImage: self.groupViewModel.image)
                  .renderingMode(.template) // makes this VV color work
                  .foregroundColor(paint_color)
                  .contentShape(Rectangle())
                  .blendMode(.hardLight)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
            }
              .offset(x: CGFloat(outlier_min.x),
                      y: CGFloat(outlier_min.y) - frame_height + CGFloat(self.groupViewModel.bounds.height))
              .frame(width: CGFloat(self.groupViewModel.bounds.width),
                     height: CGFloat(self.groupViewModel.bounds.height))
              .onHover { self.groupViewModel.arrowSelected = $0 }
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if let origShouldPaint = self.groupViewModel.group.shouldPaint {
                      // change the paintability of this outlier group
                      // set it to user selected opposite previous value
                      Task {
                          if self.groupViewModel.viewModel.selectionMode == .details {
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
                                          self.groupViewModel.viewModel.showOutlierGroupTableWindow()
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
}

