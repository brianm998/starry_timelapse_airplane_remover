import SwiftUI
import StarCore

// the view model for a single outlier group

class OutlierGroupViewModel: ObservableObject {

    init (viewModel: ViewModel,
          group: OutlierGroup,
          name: String,
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
    let name: String
    let bounds: BoundingBox
    let image: NSImage

    var selectionColor: Color {
        if isSelected { return .blue }

        let will_paint = self.willPaint
        
        if will_paint == nil { return .orange }
        if will_paint! { return .red }
        return .green
    }

    var willPaint: Bool? { group.shouldPaint?.willPaint }

    var view: some View {
        return OutlierGroupView(groupViewModel: self)
    }
    
}
