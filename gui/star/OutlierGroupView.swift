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

    /// The id a UI test finds this group by (`gherkin/ui/ids.json`), for the one group that carries it, and only under `-StarUITestProbes YES`.
    var probeId: String? = nil

    @Environment(\.openWindow) private var openWindow

    /// What a click on a group does once the trash and information tools have had theirs.
    enum GroupClick: Equatable { case applyTool, openMultiChoice }

    /// With the "Multi Choice" switch on, a click on a group that has a decision opens the multi-choice sheet; otherwise it applies the tool
    /// (a toggle for Remove, Keep and Multi). Trash and Information keep their meaning. `gherkin/ui/vectors/clickRules.json` pins this and
    /// the desktop's `ClickRules.groupClick` to the same table.
    static func groupClick(tool: ToolType, multiChoice: Bool, decided: Bool) -> GroupClick {
        if tool == .trash || tool == .information { return .applyTool }
        return multiChoice && decided ? .openMultiChoice : .applyTool
    }

    /// The decision a click leaves. A group that has one is flipped, whichever tool is chosen; one that has none takes the tool's: Keep keeps
    /// it and every other tool removes it. (The click used to ignore the tool, so Keep marked an undecided group for removal.)
    static func decisionAfterClick(_ current: RemoveReason?, tool: ToolType) -> RemoveReason {
        guard let current else { return .userSelected(tool != .keep) }
        return .userSelected(!current.willRemove)
    }

    /// A group as the probe choice sees it: its id, its bounds in frame pixels and its pixel count, in the order the groups are drawn
    /// (the last one is on top).
    struct ProbeCandidate: Equatable {
        let id: UInt16
        let bounds: BoundingBox
        let size: UInt
    }

    /// The group a UI test clicks (`outlier.first`). It must be one a click can hit: the smallest group is often under a point wide at the
    /// size the frame is shown at (0.9 x 0.3 pt in the default window), and XCUITest never reports such an element hittable, so the run
    /// waited out its 60 s on it. Among the groups with more than `minSize` pixels whose box is at least `minPoints` on screen both ways
    /// (the desktop tags a fixed 6 dp box), this takes the smallest one whose centre no later-drawn group covers, because a click on the
    /// centre would land on that group instead. When none qualifies it is the smallest group over `minSize`, as it used to be.
    /// - Parameters:
    ///   - groups: the candidates in drawing order
    ///   - pointsPerPixel: how many points a frame pixel takes up on screen
    static func probeGroupId(groups: [ProbeCandidate],
                             pointsPerPixel: CGFloat,
                             minSize: UInt = 40,
                             minPoints: CGFloat = 6) -> UInt16?
    {
        let big = groups.indices.filter { groups[$0].size > minSize }
        func area(_ i: Int) -> Int { groups[i].bounds.size }

        let hittable = big.filter { i in
            let b = groups[i].bounds
            guard CGFloat(b.width) * pointsPerPixel >= minPoints,
                  CGFloat(b.height) * pointsPerPixel >= minPoints else { return false }
            let c = b.centerDouble
            return !groups.indices.contains { j in
                guard j > i else { return false }
                let o = groups[j].bounds
                return c.x >= Double(o.min.x) && c.x <= Double(o.max.x + 1) && c.y >= Double(o.min.y) && c.y <= Double(o.max.y + 1)
            }
        }
        // `min(by:)` keeps the first of equals; the old rule kept the last one drawn, which is the one on top
        let pick = hittable.reversed().min { area($0) < area($1) } ?? big.reversed().min { area($0) < area($1) }
        return pick.map { groups[$0].id }
    }

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
              .tagged(probeId)

            // tap gesture toggles paintability of the tapped group
              .onTapGesture {
                  if viewModel.selectionMode == .trash {
                      // dump the tapped outlier into the trash
                      viewModel.frames[groupViewModel.group.frameIndex].dumpInTrash(groupViewModel.group)
                      topViewModel.refreshCursor()
                  } else if viewModel.selectionMode == .information {
                      // list this group's details, whatever its decision: an undecided group used to fall through
                      // to the toggle below and was marked for removal by looking at it
                      handleDetailsMode()
                  } else {                   
                      Task {
                          let origShouldPaint = await groupViewModel.group.shouldRemove() 
                          
                          await MainActor.run {
                              Log.d("viewModel.selectionMode \(viewModel.selectionMode)")
                              switch Self.groupClick(tool: viewModel.selectionMode,
                                                     multiChoice: viewModel.multiChoice,
                                                     decided: origShouldPaint != nil) {
                              case .openMultiChoice:
                                  openMultiChoiceSheet()
                              case .applyTool:
                                  // change the paintability of this outlier group: the opposite of what it was, or the tool's decision
                                  // for a group that had none (`decisionAfterClick`)
                                  toggleRemoveReason(origShouldPaint) {
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
                    Text(localized("ui.calculating_line"))
                      .foregroundColor(.white)
                }
                
                // draw line here
                if self.groupViewModel.line != nil {
                    Path { path in
                        path.addLines(self.groupViewModel.pointsForLineOnBounds)
                        path.closeSubpath()
                    }
                      .stroke(.white, lineWidth: 8)
                      .opacity(0.33)
                } else if !self.groupViewModel.lineIsLoading,
                          !self.groupViewModel.hasLine
                {
                    Text(localized("ui.no_line"))
                      .foregroundColor(.red)
                }
                
            }
            // the actual outlier group image
            Image(nsImage: self.groupViewModel.image)
              .renderingMode(.template) // makes this VV color work
              .foregroundColor(paint_color)
              .blendMode(.hardLight)

            
        }
          .frame(width: bounds_width,
                 height: bounds_height)
          .onHover { isInside in
              self.groupViewModel.selectArrow(isInside)
          }
          .cursor(self.currentCursor)
          // apply offset last
          .offset(x: CGFloat(bounds.min.x) - half_frame_width + half_bounds_width,
                  y: CGFloat(bounds.min.y) - half_frame_height + half_bounds_height)
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
        let shouldRemove = Self.decisionAfterClick(origShouldPaint, tool: viewModel.selectionMode)

        Task {
            // update the view model to show the change quickly
            await self.groupViewModel.group.shouldRemove(shouldRemove)

                                 
            // update frame view model too
            
            if let frame = viewModel.currentFrame,
               let outlierGroups = await frame.getOutlierGroups()
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

private extension View {
    /// The accessibility identifier, when there is one.
    @ViewBuilder func tagged(_ identifier: String?) -> some View {
        if let identifier { self.accessibilityIdentifier(identifier) } else { self }
    }
}
