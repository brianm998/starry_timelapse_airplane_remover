import Foundation
import SwiftUI
import Cocoa
import StarCore
import logging

// the view for a single outlier group on a frame

struct OutlierGroupView: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(ViewModel.self) var topViewModel: ViewModel

    @State var groupViewModel: OutlierGroupViewModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var groupViewModel = groupViewModel
        @Bindable var viewModel = viewModel
        ZStack() {
            let frameWidth = viewModel.frameWidth
            let frameHeight = viewModel.frameHeight
            let bounds = groupViewModel.bounds
            let unknown_paint = groupViewModel.removeObserver.shouldRemove?.willRemove == nil
            let will_paint = groupViewModel.removeObserver.shouldRemove?.willRemove ?? false
            let arrow_length = viewModel.arrowLength
            let arrow_height = viewModel.arrowHeight
            let line_width = viewModel.lineWidth
            let center_x = CGFloat(bounds.center.x)
            let center_y = CGFloat(bounds.center.y)

            let half_bounds_height = CGFloat(bounds.height/2)
            let half_bounds_width = CGFloat(bounds.width/2)

            let half_frame_height = frameHeight/2
            let half_frame_width = frameWidth/2

            let bounds_height = CGFloat(bounds.height)
            let bounds_width = CGFloat(bounds.width)

            let half_arrow_length = arrow_length/2

            if groupViewModel.arrowSelected || will_paint || unknown_paint || groupViewModel.isSelected {
                // arrow indicators on the side of the image

                // arrow on left side
                arrowImage(named: "arrow.right")
                  .cursor(self.currentCursor)
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: -half_arrow_length - half_frame_width,
                          y: center_y - half_frame_height/* + half_bounds_height*/)

                // arrow on top
                arrowImage(named: "arrow.down")
                  .cursor(self.currentCursor)
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - half_frame_width/* - half_bounds_width*/,
                          y: -half_frame_height - half_arrow_length)

                // arrow on right side
                arrowImage(named: "arrow.left")
                  .cursor(self.currentCursor)
                  .frame(width: arrow_length, height: arrow_height)
                  .offset(x: half_frame_width + half_arrow_length,
                          y: center_y - half_frame_height/* + half_bounds_height*/)
                

                // arrow on bottom 
                arrowImage(named: "arrow.up")
                  .cursor(self.currentCursor)
                  .frame(width: arrow_height, height: arrow_length)
                  .offset(x: center_x - half_frame_width/* - half_bounds_width*/,
                          y: half_arrow_length + half_frame_height)
            }
            
            if groupViewModel.arrowSelected || groupViewModel.isSelected {
                
                // lines across the frame between the arrows and outlier group bounds
                let left_line_width = CGFloat(bounds.min.x)

                let right_line_width = viewModel.frameWidth -
                  left_line_width - bounds_width

                let top_line_height = CGFloat(bounds.min.y)

                let bottom_line_height = viewModel.frameHeight -
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

            self.outlierView
              .onHover { isInside in
                  groupViewModel.selectArrow(isInside)
              }
              .cursor(self.currentCursor)
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if viewModel.selectionMode == .trash {
                      // dump the tapped outlier into the trash
                      viewModel.frames[groupViewModel.group.frameIndex].dumpInTrash(groupViewModel.group)
                      topViewModel.refreshCursor()
                  } else {                   
                      Task {
                          let origShouldPaint = await groupViewModel.group.shouldRemove() 
                          
                          await MainActor.run {
                              if let origShouldPaint {
                                  // change the paintability of this outlier group
                                  // set it to user selected opposite previous value

                                  Log.d("viewModel.selectionMode \(viewModel.selectionMode)")
                                  
                                  if viewModel.selectionMode == .information {
                                      handleDetailsMode()
                                  } else if viewModel.multiChoice {
                                      openMultiChoiceSheet()
                                  } else {
                                      toggleRemoveReason(origShouldPaint) {
                                          topViewModel.refreshCursor()
                                      }
                                  }
                              } else {
                                  // handle outliers without a paint decision 
                                  toggleRemoveReason() {
                                      topViewModel.refreshCursor()
                                  }
                              }
                          }
                      }
                  }
            } 
        }
    }

    func currentCursor() -> NSCursor {
        switch viewModel.selectionMode {
        case .trash:
            return .deleteTrashPointing
        case .information:
            return .infoPointing
        default: 
            if let willRemove = groupViewModel.willRemove {
                if willRemove {
                    return .keepPointing
                } else {
                    return .removePointing
                }
            } else {
                return .removePointing
            }
        }
    }

    var outlierView: some View {
        let bounds = self.groupViewModel.bounds
        let frameWidth = viewModel.frameWidth
        let frameHeight = viewModel.frameHeight
        let half_bounds_height = CGFloat(bounds.height/2)
        let half_bounds_width = CGFloat(bounds.width/2)
        let paint_color = self.groupViewModel.groupColor
        let half_frame_height = frameHeight/2
        let half_frame_width = frameWidth/2
        let bounds_height = CGFloat(bounds.height)
        let bounds_width = CGFloat(bounds.width)

        return ZStack(alignment: .topLeading) {
            if self.groupViewModel.arrowSelected || self.groupViewModel.isSelected {
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
                } else if !self.groupViewModel.lineIsLoading,
                          !self.groupViewModel.hasLine
                {
                    Text("No Line")
                      .foregroundColor(.red)
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

    }
    
    // used when user taps on outlier group in with selection mode set to details
    func handleDetailsMode() {
        Task {
            Log.w("DETAILS")
            // here we want to select just this outlier

            if viewModel.outlierGroupTableRows.count == 1,
               viewModel.outlierGroupTableRows[0].name == self.groupViewModel.group.id
            {
                // just toggle the selectablility of this one
                // XXX need separate enums for selection does paint and selection does do info
            } else {
                // make this row the only selected one
                let frame_view = viewModel.frames[self.groupViewModel.group.frameIndex]
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
                        viewModel.outlierGroupWindowFrame = frame
                        viewModel.outlierGroupTableRows = [new_row]
                        viewModel.selectedOutliers = [new_row.id]

                        if viewModel.shouldShowOutlierGroupTableWindow() {
                            openWindow(id: StarApp.outlierGroupTableWindowName) 
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
        viewModel.multiChoiceSheetShowing = true
        viewModel.multiChoiceOutlierView = self
        Task {
            let shouldRemove = await self.groupViewModel.group.shouldRemove()
            await MainActor.run {
                if let shouldRemove {
                    if shouldRemove.willRemove {
                        viewModel.multiChoicePaintType = .keep
                    } else {
                        viewModel.multiChoicePaintType = .remove
                    }
                } else {
                    // this is aguess
                    viewModel.multiChoicePaintType = .keep
                }
            }
        }
    }
    
    // used when user selects an outlier group outisde of details selection mode 
    func toggleRemoveReason(_ origShouldPaint: RemoveReason? = nil, closure: @escaping () -> Void) {
        var will_paint = false
        if let origShouldPaint = origShouldPaint {
            will_paint = origShouldPaint.willRemove
        }
        let shouldRemove = RemoveReason.userSelected(!will_paint)

        Task {
            // update the view model to show the change quickly
            await self.groupViewModel.group.shouldRemove(shouldRemove)

                                 
            // update frame view model too
            
            if let frame = viewModel.currentFrame,
               let outlierGroups = await frame.outlierGroups
            {
                if let outlier_group = await outlierGroups.members[self.groupViewModel.group.id] {
                    // update the outlier group in the background
                    await outlier_group.shouldRemove(shouldRemove)
                    await frame.markAsChanged()
                    Task { @MainActor in
                        closure()
                    }
                } else {
                    Log.e("HOLY FUCK")
                }
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
                  let shouldRemove = await group.shouldRemove()
                  await MainActor.run {
                      toggleRemoveReason(shouldRemove) {
                          topViewModel.refreshCursor()
                      }
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
}

