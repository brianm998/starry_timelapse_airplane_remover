import SwiftUI
import StarCore

// the view model for a single outlier group

@Observable
class OutlierGroupViewModel {

    init (viewModel: ViewModel,
          group: OutlierGroup,
          name: UInt16,
          bounds: BoundingBox,
          image: NSImage)
    {
        self.viewModel = viewModel
        self.group = group
        self.name = name
        self.bounds = bounds
        self.image = image

        Task {
            await self.group.set(shouldPaintDidChange: { [weak self] group, paintReason in
                if let self {
                    self.setWillPaint(from: paintReason)
                }
            })

            self.setWillPaint(from: await group.shouldPaint)
        }
    }

    fileprivate func setWillPaint(from paintReason: PaintReason?) {
        Task { @MainActor in 
            if let paintReason {
                self.willPaint = paintReason.willPaint
            } else {
                self.willPaint = nil
            }
        }
    }
    
    deinit {
      Task { await self.group.set(shouldPaintDidChange: nil) }
    }
    
    var viewModel: ViewModel
    
    var arrowSelected = false // hovered over on frame view

    var isSelected = false // selected for the details view

    var willPaint: Bool?

    let group: OutlierGroup
    let name: UInt16
    let bounds: BoundingBox
    let image: NSImage

    func selectArrow(_ selected: Bool) {
        Task {
            if selected,
               let frame = await group.frame,
               let outlierViewModels = await viewModel.frames[frame.frameIndex].outlierViews
            {
                // deselect all others first
                for outlierViewModel in outlierViewModels {
                    if outlierViewModel.name != name,
                       outlierViewModel.arrowSelected
                    {
                        await MainActor.run {
                            outlierViewModel.arrowSelected = false
                        }
                    }
                }
            }
            await MainActor.run {
                arrowSelected = selected
            }
        }
    }
    
    var groupColor: Color {
        if isSelected { return .blue }

        if let will_paint = self.willPaint {
            if will_paint {
                return .red
            } else {
                return .green
            }
        } else {
            return .orange
        }
    }
    
    var arrowColor: Color {

        if let will_paint = self.willPaint {
            if self.arrowSelected {            
                if will_paint {
                    return .red
                } else {
                    return .green
                }
            } else {
                return .white
            }
        } else {
            return .orange
        }
    }

    var view: some View {
        return OutlierGroupView(groupViewModel: self)
          .environment(viewModel)
    }
    
}
