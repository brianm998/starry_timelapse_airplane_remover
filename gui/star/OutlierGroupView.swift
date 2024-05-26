import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging

// the view for a single outlier group on a frame

struct OutlierGroupView: View {

    @ObservedObject var groupViewModel: OutlierGroupViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // .bottomLeading alignment is used to avoid a bug in .onHover and onTap
        // which is described in more detail in FrameEditView
        ZStack(/*alignment: .bottomLeading*/) {
            let frameWidth = self.groupViewModel.viewModel.frameWidth
            let frameHeight = self.groupViewModel.viewModel.frameHeight
            let bounds = self.groupViewModel.bounds
            let unknown_paint = self.groupViewModel.willPaint == nil
            let will_paint = self.groupViewModel.willPaint ?? false
            let paint_color = self.groupViewModel.groupColor
            let arrow_length = self.arrowLength
            let arrow_height = self.arrowHeight
            let line_width = self.lineWidth
            let center_x = CGFloat(bounds.center.x)
            let center_y = CGFloat(bounds.center.y)

            if self.groupViewModel.arrowSelected || will_paint || unknown_paint {
                // arrow indicators on the side of the image

                // arrow on left side
                arrowImage(named: "arrow.right")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: -arrow_length/2 - frameWidth/2,
                          y: center_y - frameHeight/2 + CGFloat(bounds.height/2))

                // arrow on top
                arrowImage(named: "arrow.down")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - frameWidth/2 - CGFloat(bounds.width/2),
                          y: -frameHeight/2 - arrow_length/2)

                // arrow on right side
                arrowImage(named: "arrow.left")
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: frameWidth/2 + arrow_length/2,
                          y: center_y - frameHeight/2 + CGFloat(bounds.height/2))

                // arrow on bottom 
                arrowImage(named: "arrow.up")
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - frameWidth/2 - CGFloat(bounds.width/2),
                          y: arrow_length/2 + frameHeight/2)
            }
            
            if self.groupViewModel.arrowSelected {

                let _ = Log.d("CRAPPY bounds \(bounds) frameWidth \(groupViewModel.viewModel.frameWidth) frameHeight \(groupViewModel.viewModel.frameHeight)")
                
                // lines across the frame between the arrows and outlier group bounds
                let left_line_width = CGFloat(bounds.min.x - bounds.width/2)

                let right_line_width = groupViewModel.viewModel.frameWidth -
                  left_line_width - CGFloat(bounds.width)

                let top_line_height = CGFloat(bounds.min.y + bounds.height/2)

                let bottom_line_height = groupViewModel.viewModel.frameHeight -
                  top_line_height - CGFloat(bounds.height)

                // left line
                outlierFrameLine()
                  .frame(width: left_line_width,
                         height: line_width)
                  .offset(x: -frameWidth / 2 + left_line_width / 2,
                          y: CGFloat(bounds.center.y) - frameHeight/2 + CGFloat(bounds.height/2))

                // top line 
                outlierFrameLine()
                  .frame(width: line_width,
                         height: top_line_height)
                  .offset(x: CGFloat(bounds.center.x)-frameWidth / 2 - CGFloat(bounds.width/2),
                          y: -frameHeight / 2 + top_line_height / 2)

                // right line
                outlierFrameLine()
                  .frame(width: right_line_width,
                         height: line_width)
                  .offset(x: CGFloat(bounds.center.x)-frameWidth/2 + right_line_width / 2,
                          y: CGFloat(bounds.center.y) - frameHeight / 2 + CGFloat(bounds.height/2))


                // bottom line
                outlierFrameLine()
                  .frame(width: line_width,
                         height: bottom_line_height)
                  .offset(x: CGFloat(bounds.center.x) - frameWidth / 2 - CGFloat(bounds.width/2),
                          y: CGFloat(bounds.center.y)-frameHeight/2 + bottom_line_height / 2 + CGFloat(bounds.height))
            }
            
            ZStack(/*alignment: .bottomLeading*/) {
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
                }
                // the actual outlier group image
                Image(nsImage: self.groupViewModel.image)
                  .renderingMode(.template) // makes this VV color work
                  .foregroundColor(paint_color)
                  .blendMode(.hardLight)
            }
              .offset(x: CGFloat(bounds.min.x) - frameWidth/2,
                      y: CGFloat(bounds.min.y) - frameHeight/2 + CGFloat(bounds.height))
              .frame(width: CGFloat(bounds.width),
                     height: CGFloat(bounds.height))
              .onHover { self.groupViewModel.selectArrow($0) }
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if let origShouldPaint = self.groupViewModel.group.shouldPaint {
                      // change the paintability of this outlier group
                      // set it to user selected opposite previous value
                      if self.groupViewModel.viewModel.selectionMode == .details {
                          handleDetailsMode()
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
                   let group = frame.outlierGroup(named: self.groupViewModel.group.id)
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

    // used when user selects an outlier group outisde of details selection mode 
    func togglePaintReason(_ origShouldPaint: PaintReason? = nil) {
        var will_paint = true
        if let origShouldPaint = origShouldPaint {
            will_paint = origShouldPaint.willPaint
        }
        let shouldPaint = PaintReason.userSelected(!will_paint)
        
        // update the view model to show the change quickly
        self.groupViewModel.group.shouldPaint = shouldPaint
        self.groupViewModel.objectWillChange.send() 

        Task {
            if let frame = self.groupViewModel.viewModel.currentFrame,
               let outlierGroups = frame.outlierGroups,
               let outlier_group = outlierGroups.members[self.groupViewModel.group.id]
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
              togglePaintReason(self.groupViewModel.group.shouldPaint)
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

