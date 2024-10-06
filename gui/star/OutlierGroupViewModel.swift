import SwiftUI
import StarCore
import Combine

// the view model for a single outlier group

@MainActor @Observable
class OutlierGroupViewModel: Identifiable {

    // XXX make the UI use this to see changes in paintability
    var paintObserver = OutlierPaintObserver() 
    
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
            await group.set(paintObserver: paintObserver)
            if let shouldPaint = await group.shouldPaint() {
                paintObserver.shouldPaint = shouldPaint
            }
        }
    }

    let id = UUID()
    
    fileprivate func setWillPaint(from paintReason: PaintReason?) {
        paintObserver.shouldPaint = paintReason
    }

    
    deinit {
     // let group = self.group
    //  Task { await group.set(shouldPaintDidChange: nil) }
    }
    
    var viewModel: ViewModel
    
    var arrowSelected = false // hovered over on frame view

    var isSelected = false // selected for the details view

//    var willPaint: Bool?

    let group: OutlierGroup
    let name: UInt16
    let bounds: BoundingBox
    let image: NSImage

    func selectArrow(_ selected: Bool) {
        arrowSelected = selected
        Task {
            if selected,
               let frame = await group.frame
            {
                let frameIndex = frame.frameIndex
                await MainActor.run {
                    if let outlierViewModels = viewModel.frames[frameIndex].outlierViews {
                        // deselect all others first
                        for outlierViewModel in outlierViewModels {
                            if outlierViewModel.name != name,
                               outlierViewModel.arrowSelected
                            {
                                outlierViewModel.arrowSelected = false
                            }
                        }
                    }
                }
            }
        }
    }
    
    var groupColor: Color {
        if isSelected { return .blue }

        if let will_paint = self.paintObserver.shouldPaint {
          if will_paint.willPaint {
                return .red
            } else {
                return .green
            }
        } else {
            return .orange
        }
    }
    
    var arrowColor: Color {

        if let will_paint = self.paintObserver.shouldPaint {
            if self.arrowSelected {            
              if will_paint.willPaint {
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
/*
    var view: some View {
        OutlierGroupView(groupViewModel: self)
          .environment(viewModel)
    }
  */  
}
