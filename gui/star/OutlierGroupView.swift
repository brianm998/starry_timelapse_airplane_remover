import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging

// the view for a single outlier group on a frame

struct OutlierGroupView: View {

    @State var groupViewModel: OutlierGroupViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // .bottomLeading alignment is used to avoid a bug in .onHover and onTap
        // which is described in more detail in FrameEditView
        ZStack() {
            let frameWidth = self.groupViewModel.viewModel.frameWidth
            let frameHeight = self.groupViewModel.viewModel.frameHeight
            let bounds = self.groupViewModel.bounds
            let unknown_paint = self.groupViewModel.paintObserver.shouldPaint?.willPaint == nil
            let will_paint = self.groupViewModel.paintObserver.shouldPaint?.willPaint ?? false
            let paint_color = self.groupViewModel.groupColor
            let arrow_length = self.arrowLength
            let arrow_height = self.arrowHeight
            let line_width = self.lineWidth
            let center_x = CGFloat(bounds.center.x)
            let center_y = CGFloat(bounds.center.y)

            let half_bounds_height = CGFloat(bounds.height/2)
            let half_bounds_width = CGFloat(bounds.width/2)

            let half_frame_height = frameHeight/2
            let half_frame_width = frameWidth/2

            let bounds_height = CGFloat(bounds.height)
            let bounds_width = CGFloat(bounds.width)

            let half_arrow_length = arrow_length/2

            if self.groupViewModel.arrowSelected || will_paint || unknown_paint {
                // arrow indicators on the side of the image

                // arrow on left side
                arrowImage(named: "arrow.right")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: -half_arrow_length - half_frame_width,
                          y: center_y - half_frame_height/* + half_bounds_height*/)

                // arrow on top
                arrowImage(named: "arrow.down")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - half_frame_width/* - half_bounds_width*/,
                          y: -half_frame_height - half_arrow_length)

                // arrow on right side
                arrowImage(named: "arrow.left")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: half_frame_width + half_arrow_length,
                          y: center_y - half_frame_height/* + half_bounds_height*/)

                // arrow on bottom 
                arrowImage(named: "arrow.up")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - half_frame_width/* - half_bounds_width*/,
                          y: half_arrow_length + half_frame_height)
            }
            
            if self.groupViewModel.arrowSelected {
                
                // lines across the frame between the arrows and outlier group bounds
                let left_line_width = CGFloat(bounds.min.x)

                let right_line_width = groupViewModel.viewModel.frameWidth -
                  left_line_width - bounds_width

                let top_line_height = CGFloat(bounds.min.y)

                let bottom_line_height = groupViewModel.viewModel.frameHeight -
                  top_line_height - bounds_height

                let bounds_center_x = CGFloat(bounds.center.x)
                let bounds_center_y = CGFloat(bounds.center.y)
                
                // left line
                outlierFrameLine()
                  .frame(width: left_line_width,
                         height: line_width)
                  .offset(x: -half_frame_width + left_line_width / 2,
                          y: bounds_center_y - half_frame_height)

                // top line 
                outlierFrameLine()
                  .frame(width: line_width,
                         height: top_line_height)
                  .offset(x: bounds_center_x-half_frame_width,
                          y: -half_frame_height + top_line_height / 2)

                // right line
                outlierFrameLine()
                  .frame(width: right_line_width,
                         height: line_width)
                  .offset(x: bounds_center_x-half_frame_width +
                            right_line_width / 2 + half_bounds_width,
                          y: bounds_center_y - half_frame_height)

                // bottom line
                outlierFrameLine()
                  .frame(width: line_width,
                         height: bottom_line_height)
                  .offset(x: bounds_center_x - half_frame_width,
                          y: bounds_center_y-half_frame_height +
                            bottom_line_height / 2 + half_bounds_height)
            }
            
            ZStack(alignment: .topLeading) {
                if self.groupViewModel.arrowSelected {
                    // underlay for when this outlier group is hovered over
                    Rectangle() // fill that is transparent
                      .foregroundColor(paint_color)
                      .opacity(1.0/8)
                    Rectangle() // a border that's not transparent
                      .stroke(style: StrokeStyle(lineWidth: 4))
                      .foregroundColor(paint_color)
                      .blendMode(.difference)
                      .opacity(0.5)

                    if self.groupViewModel.lineIsLoading {
                        Text("calculating line ...")
                          .foregroundColor(.white)
                    }
                    
                    // draw line here
                    if let line = self.groupViewModel.line {
                        Path { path in
                            path.addLines(self.groupViewModel.pointsForLineOnBounds)
                            path.closeSubpath()
                        }
                          .stroke(.white, lineWidth: 8)
                          .opacity(0.33)
                    }
                    
                }
                // the actual outlier group image
                Image(nsImage: self.groupViewModel.image)
                  .renderingMode(.template) // makes this VV color work
                  .foregroundColor(paint_color)
                  .blendMode(.hardLight)

                
            }
              .offset(x: CGFloat(bounds.min.x) - half_frame_width + half_bounds_width,
                      y: CGFloat(bounds.min.y) - half_frame_height + half_bounds_height)
              .frame(width: bounds_width,
                     height: bounds_height)
              .onHover { self.groupViewModel.selectArrow($0) }
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  Task {
                      let origShouldPaint = await self.groupViewModel.group.shouldPaint() 

                      await MainActor.run {
                          if let origShouldPaint {
                              // change the paintability of this outlier group
                              // set it to user selected opposite previous value
                              
                              if self.groupViewModel.viewModel.selectionMode == .details {
                                  handleDetailsMode()
                              } else if self.groupViewModel.viewModel.multiChoice {
                                  openMultiChoiceSheet()
                              } else {
                                  togglePaintReason(origShouldPaint)
                              }
                          } else {
                              // handle outliers without a paint decision 
                              togglePaintReason()
                          }
                      }
                  }
              }
        }
    }

    // used when user taps on outlier group in with selection mode set to details
    func handleDetailsMode() {
        Task {
            Log.w("DETAILS")
            // here we want to select just this outlier

            if self.groupViewModel.viewModel.outlierGroupTableRows.count == 1,
               self.groupViewModel.viewModel.outlierGroupTableRows[0].name == self.groupViewModel.group.id
            {
                // just toggle the selectablility of this one
                // XXX need separate enums for selection does paint and selection does do info
            } else {
                // make this row the only selected one
                let frame_view = self.groupViewModel.viewModel.frames[self.groupViewModel.group.frameIndex]
                if let frame = frame_view.frame,
                   let group = await frame.outlierGroup(named: self.groupViewModel.group.id)
                {
                    if let outlier_views = frame_view.outlierViews {
                        for outlier_view in outlier_views {
                            if outlier_view.name != self.groupViewModel.group.id {
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
                    }
                } else {
                    Log.w("couldn't find frame")
                }
            }
        }
    }

    func openMultiChoiceSheet() {
        // show a dialog like the multi selection dialog
        // which allows changing any outlier groups in other
        // frames which have any pixels in the same spot
        self.groupViewModel.viewModel.multiChoiceSheetShowing = true
        self.groupViewModel.viewModel.multiChoiceOutlierView = self
        Task {
            let shouldPaint = await self.groupViewModel.group.shouldPaint()
            await MainActor.run {
                if let shouldPaint {
                    if shouldPaint.willPaint {
                        self.groupViewModel.viewModel.multiChoicePaintType = .clear
                    } else {
                        self.groupViewModel.viewModel.multiChoicePaintType = .paint
                    }
                } else {
                    // this is aguess
                    self.groupViewModel.viewModel.multiChoicePaintType = .clear
                }
            }
        }
    }
    
    // used when user selects an outlier group outisde of details selection mode 
    func togglePaintReason(_ origShouldPaint: PaintReason? = nil) {
        var will_paint = true
        if let origShouldPaint = origShouldPaint {
            will_paint = origShouldPaint.willPaint
        }
        let shouldPaint = PaintReason.userSelected(!will_paint)
        

        Task {
            // update the view model to show the change quickly
            await self.groupViewModel.group.shouldPaint(shouldPaint)
            
            if let frame = self.groupViewModel.viewModel.currentFrame,
               let outlierGroups = await frame.outlierGroups,
               let outlier_group = await outlierGroups.members[self.groupViewModel.group.id]
            {
                // update the outlier group in the background
                await outlier_group.shouldPaint(shouldPaint)
            } else {
                Log.e("HOLY FUCK")
            }
        }
    }

    // images for arrows at edge of frame that point towards outlier groups
    private func arrowImage(named imageName: String) -> some View {
        Image(systemName: imageName)
          .resizable()
          .foregroundColor(self.groupViewModel.arrowColor)
          .onHover { self.groupViewModel.selectArrow($0) }
          .onTapGesture {
              let group = self.groupViewModel.group
              Task {
                  let shouldPaint = await group.shouldPaint()
                  await MainActor.run {
                      togglePaintReason(shouldPaint)
                  }
              }
          }
    }

    public func outlierFrameLine() -> some View {
        Rectangle()
          .foregroundColor(self.groupViewModel.arrowColor)
          .blendMode(.difference)
          .opacity(0.5)
    }
    
    private var arrowLength: CGFloat {
        let viewModel = self.groupViewModel.viewModel
        let frameWidth = viewModel.frameWidth
        return frameWidth/viewModel.outlierArrowLength
    }

    private var arrowHeight: CGFloat {
        let viewModel = self.groupViewModel.viewModel
        let frameWidth = viewModel.frameWidth
        return frameWidth/viewModel.outlierArrowHeight
    }
    
    private var lineWidth: CGFloat { self.arrowHeight/8 }
}

