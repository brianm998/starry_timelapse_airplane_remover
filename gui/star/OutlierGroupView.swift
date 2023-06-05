import Foundation
import SwiftUI
import Cocoa
import StarCore

// the view for a single outlier group on a frame

struct OutlierGroupView: View {
    @ObservedObject var groupViewModel: OutlierGroupViewModel

    var body: some View {
        ZStack {
            let frame_center_x = self.groupViewModel.frame_width/2
            let frame_center_y = self.groupViewModel.frame_height/2
            let outlier_center = self.groupViewModel.bounds.center
            
            let will_paint = self.groupViewModel.willPaint ?? false
            
            let paint_color = self.groupViewModel.selectionColor

            let arrow_length:CGFloat = CGFloat(self.groupViewModel.frame_width)/20
            let arrow_height:CGFloat = CGFloat(self.groupViewModel.frame_width)/400
            
            if will_paint {
                // stick some indicators on the side of the image

                // right side
                Rectangle()
                  .foregroundColor(.purple)
                  .offset(x: CGFloat(frame_center_x)+arrow_length/2,
                          y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // upper
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                          y: -arrow_length/2 - CGFloat(frame_center_y))
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // left side
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: -arrow_length/2 - CGFloat(frame_center_x),
                          y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }

                // lower
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                          y: CGFloat(frame_center_y) + arrow_length/2)
                  .onHover { self.groupViewModel.arrowSelected = $0 }
                  .onTapGesture {
                      if let shouldPaint = self.groupViewModel.group.shouldPaint {
                          togglePaintReason(shouldPaint)
                      }
                  }


                // lines across the frame to mark this outlier
                if self.groupViewModel.arrowSelected {
                    let width_1 = CGFloat(outlier_center.x - self.groupViewModel.bounds.width/2)

                    // horizontal line to the left of the outlier
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: width_1,
                             height: arrow_height/4)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: -CGFloat(frame_center_x) + width_1 / 2,
                              y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))

                    let width_2 = CGFloat(groupViewModel.frame_width) -
                      width_1 -
                      CGFloat(self.groupViewModel.bounds.width)

                    // top
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: width_2,
                             height: arrow_height/4)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: -CGFloat(frame_center_x) + width_1 +  CGFloat(self.groupViewModel.bounds.width) + width_2/2,
                              y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                    
                    
                    let height_1 = CGFloat(outlier_center.y - self.groupViewModel.bounds.height/2)

                    // horizontal line to the right of the outlier
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: arrow_height/4,
                             height: height_1)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                              y: -CGFloat(frame_center_y) + height_1 / 2)

                    let height_2 = CGFloat(groupViewModel.frame_height) -
                      height_1 -
                      CGFloat(self.groupViewModel.bounds.height)
                    
                    // bottom
                    Rectangle()
                      .foregroundColor(.purple)
                      .blendMode(.difference)
                      .frame(width: arrow_height/4,
                             height: height_2)
                      .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/2)
                      .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                              y: -CGFloat(frame_center_y) + height_1 +  CGFloat(self.groupViewModel.bounds.height) + height_2/2)
                }
            }
            if self.groupViewModel.arrowSelected {
                // underlay for when this outlier group is hovered over

                Rectangle()
                  .foregroundColor(will_paint ? .purple : .yellow)
                  .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                          y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                  .frame(width: CGFloat(self.groupViewModel.bounds.width),
                         height: CGFloat(self.groupViewModel.bounds.height))
                  .opacity(groupViewModel.viewModel.outlierOpacitySliderValue/4)
            }
            Image(nsImage: self.groupViewModel.image)
              .renderingMode(.template) // makes this VV color work
              .foregroundColor(paint_color)
              .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                      y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
              .opacity(groupViewModel.viewModel.outlierOpacitySliderValue)
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

