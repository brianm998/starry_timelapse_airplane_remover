import SwiftUI
import StarCore

// the view model for a single outlier group

class OutlierGroupViewModel: ObservableObject {

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
    }

    @ObservedObject var viewModel: ViewModel
    
    @Published var arrowSelected = false // hovered over on frame view

    @Published var isSelected = false // selected for the details view

    let group: OutlierGroup
    let name: UInt16
    let bounds: BoundingBox
    let image: NSImage

    func selectArrow(_ selected: Bool) {
        if selected,
           let frame = group.frame,
           let outlierViewModels = viewModel.frames[frame.frameIndex].outlierViews
        {
            // deselect all others first
            for outlierViewModel in outlierViewModels {
                if outlierViewModel.name != name,
                   outlierViewModel.arrowSelected
                {
                    outlierViewModel.arrowSelected = false
                }
            }
        }
        arrowSelected = selected
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

    var willPaint: Bool? { group.shouldPaint?.willPaint }

    var view: some View {
        return OutlierGroupView(groupViewModel: self)
          .environmentObject(viewModel)
    }
    
}
