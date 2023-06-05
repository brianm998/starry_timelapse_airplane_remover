import Foundation
import SwiftUI
import Cocoa
import StarCore

// the view for a single outlier group on a frame

class OutlierGroupView: ObservableObject {

    init (viewModel: ViewModel,
          group: OutlierGroup,
          name: String,
          bounds: BoundingBox,
          image: NSImage,
          frame_width: Int,
          frame_height: Int)
    {
        self.viewModel = viewModel
        self.group = group
        self.name = name
        self.bounds = bounds
        self.image = image
        self.frame_width = frame_width
        self.frame_height = frame_height
    }

    @ObservedObject var viewModel: ViewModel
    
    var isSelected = false
    let group: OutlierGroup
    let name: String
    let bounds: BoundingBox
    let image: NSImage

    let frame_width: Int        // these can come from the view model
    let frame_height: Int

    var selectionColor: Color {
        if isSelected { return .blue }

        let will_paint = self.willPaint
        
        if will_paint == nil { return .orange }
        if will_paint! { return .red }
        return .green
    }

    var willPaint: Bool? { group.shouldPaint?.willPaint }
    
    var body: some View {
        ZStack {
            let frame_center_x = self.frame_width/2
            let frame_center_y = self.frame_height/2
            let outlier_center = self.bounds.center
            
            let will_paint = self.willPaint ?? false
            
            let paint_color = self.selectionColor
            
            if will_paint {
                // stick some indicators on the side of the image

                let arrow_length:CGFloat = CGFloat(self.frame_width)/20
                let arrow_height:CGFloat = CGFloat(self.frame_width)/400
                
                // right side

                Rectangle()
                  .foregroundColor(.purple)
                  .offset(x: CGFloat(frame_center_x)+arrow_length/2,
                          y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(viewModel.outlierOpacitySliderValue)
                  .onHover { over in
                      // XXX turn on state to draw lines to outlier
                      Log.w("LINE over \(over)")
                  }

                // upper
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                          y: -arrow_length/2 - CGFloat(frame_center_y))
                  .onHover { over in
                      // XXX turn on state to draw lines to outlier
                      Log.w("LINE over \(over)")
                  }

                // left side
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_length, height: arrow_height)
                  .opacity(viewModel.outlierOpacitySliderValue)
                  .offset(x: -arrow_length/2 - CGFloat(frame_center_x),
                          y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
                  .onHover { over in
                      // XXX turn on state to draw lines to outlier
                      Log.w("LINE over \(over)")
                  }

                // lower
                Rectangle()
                  .foregroundColor(.purple)
                  .frame(width: arrow_height, height: arrow_length)
                  .opacity(viewModel.outlierOpacitySliderValue)
                  .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                          y: CGFloat(frame_center_y) + arrow_length/2)
                  .onHover { over in
                      // XXX turn on state to draw lines to outlier
                      Log.w("LINE over \(over)")
                  }
            }
            Image(nsImage: self.image)
              .renderingMode(.template) // makes this VV color work
              .foregroundColor(paint_color)
              .offset(x: CGFloat(outlier_center.x) - CGFloat(frame_center_x),
                      y: CGFloat(outlier_center.y) - CGFloat(frame_center_y))
              .opacity(viewModel.outlierOpacitySliderValue)
            
            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if let origShouldPaint = self.group.shouldPaint {
                      // change the paintability of this outlier group
                      // set it to user selected opposite previous value
                      Task {
                          if self.viewModel.selectionMode == .details {
                              // here we want to select just this outlier

                              if self.viewModel.outlierGroupTableRows.count == 1,
                                 self.viewModel.outlierGroupTableRows[0].name == self.group.name
                              {
                                  // just toggle the selectablility of this one
                                  // XXX need separate enums for selection does paint and selection does do info
                              } else {
                                  // make this row the only selected one
                                  let frame_view = self.viewModel.frames[self.group.frame_index]
                                  if let frame = frame_view.frame,
                                     let group = frame.outlierGroup(named: self.group.name)
                                  {
                                      if let outlier_views = frame_view.outlierViews {
                                          for outlier_view in outlier_views {
                                              if outlier_view.name != self.group.name {
                                                  outlier_view.isSelected = false
                                              }
                                          }
                                      }
                                      let new_row = await OutlierGroupTableRow(group)
                                      self.isSelected = true
                                      await MainActor.run {
                                          self.viewModel.outlierGroupWindowFrame = frame
                                          self.viewModel.outlierGroupTableRows = [new_row]
                                          self.viewModel.selectedOutliers = [new_row.id]
                                          self.viewModel.showOutlierGroupTableWindow()
                                          self.viewModel.update()

                                      }
                                  } else {
                                      Log.w("couldn't find frame")
                                  }
                              }
                              
                          } else {
                              
                              let reason = PaintReason.userSelected(!origShouldPaint.willPaint)
                              
                              // update the view model to show the change quickly
                              self.group.shouldPaint = reason
                              self.viewModel.update()
                              
                              Task {
                                  if let frame = self.viewModel.currentFrame,
                                     let outlier_groups = frame.outlier_groups,
                                     let outlier_group = outlier_groups.members[self.group.name]
                                  {
                                      // update the actor in the background
                                      await outlier_group.shouldPaint(reason)
                                      self.viewModel.update()
                                  } else {
                                      Log.e("HOLY FUCK")
                                  }
                              }
                          }
                          // update the view model so it shows up on screen
                      }
                  } else {
                      Log.e("WTF, not already set to paint??")
                  }
              }
        }
    }
}
