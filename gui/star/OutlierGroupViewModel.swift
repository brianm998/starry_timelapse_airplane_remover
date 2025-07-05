import SwiftUI
import StarCore
import Combine
import KHTSwift
import logging

// the view model for a single outlier group

@MainActor @Observable
class OutlierGroupViewModel: Identifiable {

    // XXX make the UI use this to see changes in paintability
    var removeObserver = OutlierRemovalObserver() 
    
    init(viewModel: FrameViewModel,
         group: OutlierGroup,
         name: UInt16,
         bounds: BoundingBox,
         image: NSImage) async
    {
        self.viewModel = viewModel
        self.group = group
        self.name = name
        self.bounds = bounds
        self.image = image

        await group.set(removeObserver: removeObserver)
        if let shouldRemove = await group.shouldRemove() {
            removeObserver.shouldRemove = shouldRemove
        }
    }

    let id = UUID()
    
    fileprivate func setWillPaint(from paintReason: RemoveReason?) {
        removeObserver.shouldRemove = paintReason
    }

    private var _line: Line?

    public var lineLoaded = false
    
    var line: Line? {

        if !lineLoaded {        // lazy load in the background, can take awhile
            Task.detached {
                if let line = await self.group.line() {
                    await MainActor.run {
                        self._line = line
                        self.lineIsLoading = false
                        self.hasLine = false
                    }
                } else {
                    await MainActor.run {
                        self.lineIsLoading = false
                    }
                }
            }
        }
        
        return _line
    }

    var hasLine = false
    var lineIsLoading = true
    
    var pointsForLineOnBounds: [CGPoint] {
        if let line {
            let zeroCentered = self.group.bounds.zeroCentered
            let points = zeroCentered.allIntersections(with: line.standardLine)
            return points.map { CGPoint(x: $0.x, y: $0.y) }
        }
        return []
    }
    
    deinit {
     // let group = self.group
    //  Task { await group.set(shouldRemoveDidChange: nil) }
    }
    
    weak var viewModel: FrameViewModel?
    
    var arrowSelected = false // hovered over on frame view

    var isSelected = false // selected for the details view

//    var willRemove: Bool?

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
                    if let viewModel,
                       let outlierViewModels = viewModel.outlierViews
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
                }
            }
        }
    }

    var willRemove: Bool? {
        if let will_paint = self.removeObserver.shouldRemove {
            return will_paint.willRemove 
        } else {
            return nil          // don't know
        }
    }
    
    var groupColor: Color {
        if isSelected { return .orange }

        if let will_paint = self.removeObserver.shouldRemove {
          if will_paint.willRemove {
                return .red
            } else {
                return .green
            }
        } else {
            return .blue
        }
    }
    
    var arrowColor: Color {
        if isSelected { return .blue }
        
        if let will_paint = self.removeObserver.shouldRemove {
            if self.arrowSelected {            
                if will_paint.willRemove {
                    return .red
                } else {
                    return .green
                }
            } else {
                return .white
            }
        } else {
            if self.arrowSelected {            
                return .red
            } else {
                return .blue
            }
        }
    }
}
