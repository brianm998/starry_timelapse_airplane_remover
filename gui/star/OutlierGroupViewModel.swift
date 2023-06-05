import SwiftUI
import StarCore

// the view model for a single outlier group

class OutlierGroupViewModel: ObservableObject {

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
    
    @Published var arrowSelected = false

    @Published var isSelected = false

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

    var view: some View {
        return OutlierGroupView(groupViewModel: self)
    }
    
}
